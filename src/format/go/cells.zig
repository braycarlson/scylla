const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../../stdx/bounded/buffer.zig");
const EventsType = @import("../../syntax/tree.zig").EventsType;
const Kind = @import("../../syntax/go/kind.zig").Kind;
const Parser = @import("../../syntax/go/parse.zig").Parser;
const Token = @import("../../syntax/token.zig");
const Tokens = @import("../../syntax/tokens.zig");
const TreeType = @import("../../syntax/tree.zig").TreeType;
const escape = @import("tabwriter.zig").escape;
const lex = @import("../../syntax/lex.zig").lex;
const raw_of = @import("../../syntax/raw.zig").raw_of;
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

pub const Cells = struct {
    ends: ArrayType(u32),
    events: *Events,
    flags: ArrayType(u8),
    gaps: ArrayType(Gap),
    keeps: ArrayType(bool),
    kinds: ArrayType(Kind),
    lines: ArrayType(u32),
    lists: ArrayType(u32),
    parser: *Parser,
    tasks: ArrayType(Task),
    tokens: Tokens,
    tree: Tree,

    pub fn init(gpa: std.mem.Allocator, token_count_max: u32) std.mem.Allocator.Error!Cells {
        assert(token_count_max > 0);
        assert(task_count_max > depth_max);

        var ends: ArrayType(u32) = try .init(gpa, token_count_max);
        errdefer ends.deinit(gpa);

        const events = try gpa.create(Events);
        errdefer gpa.destroy(events);

        try events.init(gpa, token_count_max *| 4);
        errdefer events.deinit(gpa);

        var flags: ArrayType(u8) = try .init(gpa, token_count_max);
        errdefer flags.deinit(gpa);

        var gaps: ArrayType(Gap) = try .init(gpa, token_count_max);
        errdefer gaps.deinit(gpa);

        var keeps: ArrayType(bool) = try .init(gpa, token_count_max);
        errdefer keeps.deinit(gpa);

        var kinds: ArrayType(Kind) = try .init(gpa, token_count_max);
        errdefer kinds.deinit(gpa);

        var lines: ArrayType(u32) = try .init(gpa, token_count_max);
        errdefer lines.deinit(gpa);

        var lists: ArrayType(u32) = try .init(gpa, token_count_max);
        errdefer lists.deinit(gpa);

        const parser = try gpa.create(Parser);
        errdefer gpa.destroy(parser);

        var tasks: ArrayType(Task) = try .init(gpa, task_count_max);
        errdefer tasks.deinit(gpa);

        var tokens: Tokens = try .init(gpa, token_count_max);
        errdefer tokens.deinit(gpa);

        const tree: Tree = try .init(gpa, token_count_max, 1 << 10);

        assert(lines.capacity() == ends.capacity());
        assert(tasks.capacity() == task_count_max);

        return .{
            .ends = ends,
            .events = events,
            .flags = flags,
            .gaps = gaps,
            .keeps = keeps,
            .kinds = kinds,
            .lines = lines,
            .lists = lists,
            .parser = parser,
            .tasks = tasks,
            .tokens = tokens,
            .tree = tree,
        };
    }

    pub fn deinit(cells: *Cells, gpa: std.mem.Allocator) void {
        assert(cells.lines.capacity() == cells.ends.capacity());
        assert(cells.tasks.capacity() == task_count_max);

        cells.tree.deinit(gpa);
        cells.tokens.deinit(gpa);
        cells.tasks.deinit(gpa);
        gpa.destroy(cells.parser);
        cells.lists.deinit(gpa);
        cells.lines.deinit(gpa);
        cells.kinds.deinit(gpa);
        cells.keeps.deinit(gpa);
        cells.gaps.deinit(gpa);
        cells.flags.deinit(gpa);
        cells.events.deinit(gpa);
        gpa.destroy(cells.events);
        cells.ends.deinit(gpa);
        cells.* = undefined;
    }

    pub fn written(cells: *Cells, text: []const u8, out: *Buffer) error{Overflow}!void {
        assert(text.len < std.math.maxInt(u32));
        assert(cells.tasks.capacity() == task_count_max);

        out.clear();

        try cells.parsed(text);
        try cells.measured(text);

        const tail = try cells.walked();

        try cells.streamed(text, tail, out);
    }

    fn parsed(cells: *Cells, text: []const u8) error{Overflow}!void {
        assert(text.len <= std.math.maxInt(u32));

        cells.tokens.clear();

        lex(.of(.go), text, &cells.tokens) catch return error.Overflow;
        raw_of(Kind, cells.tokens.slice(), &cells.kinds) catch return error.Overflow;

        assert(cells.tokens.count() == cells.kinds.count());

        cells.tree.clear();

        const tokens = cells.tokens.slice();
        const kinds = cells.kinds.const_slice();
        const built = cells.parser.build(text, tokens, kinds, cells.events, &cells.tree);
        if (built != .complete) return error.Overflow;
        if (cells.tree.diagnostic_slice().len > 0) return error.Overflow;
        if (cells.tree.count() == 0) return error.Overflow;

        assert(cells.tree.kind_at(0) == .file);
    }

    fn measured(cells: *Cells, text: []const u8) error{Overflow}!void {
        assert(text.len <= std.math.maxInt(u32));

        const tokens = cells.tokens.slice();

        cells.lines.clear();
        cells.ends.clear();
        cells.gaps.clear();
        cells.flags.clear();

        var line: u32 = 1;
        var offset: usize = 0;

        for (tokens) |token| {
            const start: usize = token.offset;
            const inner = newlines(token.text(text));

            line += newlines(text[@min(offset, start)..start]);

            if (cells.lines.full()) return error.Overflow;
            if (cells.ends.full()) return error.Overflow;
            if (cells.gaps.full()) return error.Overflow;
            if (cells.flags.full()) return error.Overflow;

            cells.lines.push(line);
            cells.ends.push(line + inner);
            cells.gaps.push(gap_empty);
            cells.flags.push(0);

            line += inner;
            offset = @max(start, offset) + token.length;
        }

        assert(cells.lines.count() == tokens.len);
        assert(cells.flags.count() == tokens.len);
    }

    fn walked(cells: *Cells) error{Overflow}!Gap {
        cells.keeps.clear();
        cells.lists.clear();
        cells.tasks.clear();

        var walk: Walk = .{
            .ends = cells.ends.const_slice(),
            .flags = cells.flags.slice(),
            .gaps = cells.gaps.slice(),
            .keeps = &cells.keeps,
            .kinds = cells.kinds.const_slice(),
            .last = null,
            .level = 0,
            .lines = cells.lines.const_slice(),
            .lists = &cells.lists,
            .next = 0,
            .pending = gap_empty,
            .selected = false,
            .tasks = &cells.tasks,
            .tokens = cells.tokens.slice(),
            .tree = &cells.tree,
        };

        try walk.visit(0, 0);
        try walk.run();

        walk.through(@intCast(walk.kinds.len));

        assert(walk.next == walk.kinds.len);
        assert(walk.tasks.empty());

        return walk.pending;
    }

    fn streamed(cells: *Cells, text: []const u8, tail: Gap, out: *Buffer) error{Overflow}!void {
        assert(text.len <= std.math.maxInt(u32));

        var stream: Stream = .{
            .aligned = false,
            .ends = cells.ends.const_slice(),
            .flags = cells.flags.const_slice(),
            .gaps = cells.gaps.const_slice(),
            .kinds = cells.kinds.const_slice(),
            .lines = cells.lines.const_slice(),
            .out = out,
            .tail = tail,
            .text = text,
            .tokens = cells.tokens.slice(),
        };

        var previous: ?u32 = null;

        assert(stream.kinds.len == stream.tokens.len);
        assert(out.empty());

        for (stream.kinds, 0..) |kind, position| {
            if (!coded(kind)) continue;

            const at: u32 = @intCast(position);

            try stream.gap_written(previous, at);

            previous = at;
        }

        try stream.gap_written(previous, null);
    }
};

const Item = enum(u8) {
    formfeed,
    ignore,
    indent,
    newline,
    unindent,
    vtab,
};

const Gap = struct {
    count: u8,
    items: [gap_items_max]Item,

    fn push(gap: *Gap, item: Item) void {
        if (gap.count == gap_items_max) return;

        gap.items[gap.count] = item;
        gap.count += 1;

        assert(gap.count <= gap_items_max);
    }

    fn slice(gap: *const Gap) []const Item {
        assert(gap.count <= gap_items_max);

        return gap.items[0..gap.count];
    }
};

const Breaks = struct {
    count: u32,
    kinds: [break_kinds_max]u8,

    fn kind_at(breaks: Breaks, at: u32, rest: u8) u8 {
        assert(rest == '\n' or rest == 0x0c);
        assert(at < breaks.kinds.len);

        if (at >= breaks.count) return rest;
        if (at >= break_kinds_max) return rest;

        const kind = breaks.kinds[at];

        assert(kind == '\n' or kind == 0x0c);

        return kind;
    }
};

const Walk = struct {
    ends: []const u32,
    flags: []u8,
    gaps: []Gap,
    keeps: *ArrayType(bool),
    kinds: []const Kind,
    last: ?u32,
    level: u32,
    lines: []const u32,
    lists: *ArrayType(u32),
    next: u32,
    pending: Gap,
    selected: bool,
    tasks: *ArrayType(Task),
    tokens: []const Token,
    tree: *const Tree,

    fn run(walk: *Walk) error{Overflow}!void {
        assert(walk.tasks.count() <= 1);

        var resumes: u64 = 0;

        while (!walk.tasks.empty()) {
            resumes += 1;

            assert(resumes <= resume_count_max);

            const depth = walk.tasks.count();
            const task = &walk.tasks.slice()[depth - 1];

            switch (try walk.task_resume(task)) {
                .yielded => {
                    assert(walk.tasks.count() >= depth);
                    assert(walk.tasks.count() <= depth + 1);
                },
                .returned => {
                    assert(walk.tasks.count() == depth);

                    _ = walk.tasks.pop();
                },
            }
        }

        assert(walk.level == 0);
    }

    fn task_resume(walk: *Walk, task: *Task) error{Overflow}!Resumed {
        assert(!walk.tasks.empty());
        assert(task == &walk.tasks.slice()[walk.tasks.count() - 1]);

        return switch (task.*) {
            .assign => |*state| walk.assign_resume(state),
            .binary => |*state| walk.binary_resume(state),
            .block => |*state| walk.block_resume(state),
            .call => |*state| walk.call_resume(state),
            .children => |*state| walk.children_resume(state),
            .clause => |*state| walk.clause_resume(state),
            .composite => |*state| walk.composite_resume(state),
            .expr_list => |*state| walk.expr_list_resume(state),
            .field => |*state| walk.field_resume(state),
            .field_list => |*state| walk.field_list_resume(state),
            .file => |*state| walk.file_resume(state),
            .func_body => |*state| walk.func_body_resume(state),
            .gen_decl => |*state| walk.gen_decl_resume(state),
            .if_stmt => |*state| walk.if_stmt_resume(state),
            .index_list => |*state| walk.index_list_resume(state),
            .labeled => |*state| walk.labeled_resume(state),
            .listed => |*state| walk.listed_resume(state),
            .parameters => |*state| walk.parameters_resume(state),
            .return_stmt => |*state| walk.return_stmt_resume(state),
            .selector => |*state| walk.selector_resume(state),
            .spec_type => |*state| walk.spec_type_resume(state),
            .statements => |*state| walk.statements_resume(state),
            .struct_field => |*state| walk.struct_field_resume(state),
            .value_spec => |*state| walk.value_spec_resume(state),
        };
    }

    fn push_task(walk: *Walk, task: *const Task) error{Overflow}!void {
        assert(walk.tasks.count() <= task_count_max);

        if (walk.tasks.full()) return error.Overflow;

        walk.tasks.push(task.*);

        assert(!walk.tasks.empty());
    }

    fn replaced(walk: *Walk, task: *const Task) Resumed {
        assert(!walk.tasks.empty());
        assert(walk.tasks.count() <= task_count_max);

        walk.tasks.slice()[walk.tasks.count() - 1] = task.*;

        return .yielded;
    }

    fn visit(walk: *Walk, node: u32, depth: u32) error{Overflow}!void {
        assert(node < walk.tree.count());
        assert(walk.next <= walk.kinds.len);
        assert(depth < std.math.maxInt(u32));

        if (depth > depth_max) {
            walk.through(walk.end_of(node));

            return;
        }

        const task: Task = switch (walk.tree.kind_at(node)) {
            .assign_stmt => .{ .assign = .{ .depth = depth, .node = node } },
            .binary_expr => .{ .binary = .{ .depth = depth, .node = node } },
            .block_stmt => block_of(node, 1, depth),
            .call_expr => .{ .call = .{ .depth = depth, .node = node } },
            .case_clause, .comm_clause => .{ .clause = .{
                .closing = false,
                .depth = depth,
                .node = node,
            } },
            .composite_lit => .{ .composite = .{ .depth = depth, .node = node } },
            .file => .{ .file = .{
                .child = walk.tree.child_first_of(node),
                .depth = depth,
                .node = node,
            } },
            .field_list => .{ .field_list = .{ .depth = depth, .node = node } },
            .func_decl => walk.children_of(node, .func_decl, depth),
            .func_lit => walk.children_of(node, .func_lit, depth),
            .func_type => walk.children_of(node, .func_type, depth),
            .gen_decl => .{ .gen_decl = .{ .depth = depth, .node = node } },
            .if_stmt => walk.if_stmt_of(node, depth),
            .index_list_expr => .{ .index_list = .{ .depth = depth, .node = node } },
            .labeled_stmt => .{ .labeled = .{ .closing = true, .depth = depth, .node = node } },
            .return_stmt => .{ .return_stmt = .{ .depth = depth, .node = node } },
            .selector_expr => .{ .selector = .{ .depth = depth, .method = false, .node = node } },
            .select_stmt, .switch_stmt, .type_switch_stmt => walk.children_of(
                node,
                .switch_stmt,
                depth,
            ),
            .for_stmt, .range_stmt => walk.children_of(node, .headed, depth),
            else => walk.children_of(node, .generic, depth),
        };

        try walk.push_task(&task);
    }

    fn visit_statement(walk: *Walk, node: u32, closing: bool, depth: u32) error{Overflow}!void {
        assert(node < walk.tree.count());
        assert(depth > 0);

        const task: Task = switch (walk.tree.kind_at(node)) {
            .case_clause, .comm_clause => .{ .clause = .{
                .closing = closing,
                .depth = depth,
                .node = node,
            } },
            .labeled_stmt => .{ .labeled = .{ .closing = closing, .depth = depth, .node = node } },
            .if_stmt => walk.if_stmt_of(node, depth),
            else => return walk.visit(node, depth),
        };

        try walk.push_task(&task);
    }

    fn visit_spec(walk: *Walk, spec: u32, count: u32, depth: u32) error{Overflow}!void {
        assert(spec < walk.tree.count());
        assert(count > 0);
        assert(depth <= depth_max);

        const task: Task = switch (walk.tree.kind_at(spec)) {
            .value_spec => .{ .value_spec = .{
                .aligned = false,
                .depth = depth,
                .keep = false,
                .node = spec,
            } },
            .type_spec => .{ .spec_type = .{ .count = count, .depth = depth, .node = spec } },
            else => walk.children_of(spec, .generic, depth),
        };

        try walk.push_task(&task);
    }

    fn children_of(walk: *const Walk, node: u32, mode: Mode, depth: u32) Task {
        assert(node < walk.tree.count());
        assert(depth <= depth_max);

        const child = walk.tree.child_first_of(node);

        if (child) |held| assert(held > node);

        return .{ .children = .{ .child = child, .depth = depth, .mode = mode, .node = node } };
    }

    fn if_stmt_of(walk: *const Walk, node: u32, depth: u32) Task {
        assert(node < walk.tree.count());
        assert(walk.tree.kind_at(node) == .if_stmt);
        assert(depth <= depth_max);

        return .{ .if_stmt = .{
            .child = walk.tree.child_first_of(node),
            .depth = depth,
            .node = node,
            .tail = walk.end_of(node),
        } };
    }

    fn children_resume(walk: *Walk, state: *Children) error{Overflow}!Resumed {
        assert(state.node < walk.tree.count());

        const child = state.child orelse {
            walk.through(walk.end_of(state.node));

            return .returned;
        };

        assert(child > state.node);

        state.child = walk.tree.sibling_next_of(child);

        walk.through(walk.start_of(child));

        try walk.children_called(state, child);

        return .yielded;
    }

    fn children_called(walk: *Walk, state: *const Children, child: u32) error{Overflow}!void {
        assert(child > state.node);

        const held = walk.tree.at(child);
        const lone = walk.tree.sibling_next_of(child) == null;
        const depth = state.depth + 1;

        assert(depth > state.depth);

        switch (state.mode) {
            .func_decl => if (held.kind == .block_stmt) {
                return walk.push_task(&.{ .func_body = .{
                    .depth = state.depth,
                    .node = child,
                    .separator = .vtab,
                } });
            },
            .func_lit => if (held.kind == .block_stmt) {
                return walk.push_task(&.{ .func_body = .{
                    .depth = state.depth,
                    .node = child,
                    .separator = null,
                } });
            },
            .func_type => if (held.kind == .field_list) {
                if (walk.bracketed(held.token_start)) {
                    return walk.push_task(&.{ .parameters = .{ .depth = depth, .node = child } });
                }
            },
            .generic => {},
            .headed => if (held.kind == .block_stmt) {
                if (lone) return walk.push_task(&block_of(child, 1, depth));
            },
            .interface_field => if (held.kind == .func_type) {
                return walk.push_task(&walk.children_of(child, .func_type, depth));
            },
            .switch_stmt => if (held.kind == .block_stmt) {
                if (lone) return walk.switch_block(state.node, child, depth);
            },
        }

        try walk.visit(child, depth);
    }

    fn switch_block(walk: *Walk, node: u32, child: u32, depth: u32) error{Overflow}!void {
        assert(child > node);
        assert(depth <= depth_max);

        const held = walk.tree.at(child);
        const select = walk.tree.kind_at(node) == .select_stmt;
        const bare = walk.tree.child_first_of(child) == null;
        const empty = bare and !walk.comment_within(held.token_start, held.token_end);
        const skipped = select and empty;

        assert(held.kind == .block_stmt);

        if (skipped) {
            walk.through(held.token_end);

            return;
        }

        try walk.push_task(&block_of(child, 0, depth));
    }

    fn file_resume(walk: *Walk, state: *File) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .file);

        const child = state.child orelse {
            walk.through(walk.end_of(state.node));
            walk.ws(.newline);

            return .returned;
        };

        const held = walk.tree.at(child);
        const declared = held.kind == .gen_decl or held.kind == .func_decl;

        assert(child > state.node);

        state.child = walk.tree.sibling_next_of(child);

        walk.through(held.token_start);

        if (!declared) {
            try walk.visit(child, state.depth + 1);

            return .yielded;
        }

        const function = held.kind == .func_decl;
        const token: Kind = if (function) .func_keyword else walk.kinds[held.token_start];
        const repeated = if (state.previous) |kind| kind == token else false;
        const min: u32 = if (repeated) 1 else 2;
        const spans = walk.lines[held.token_start] < walk.ends[walk.final_of(child)];
        const section = token == .func_keyword and spans;

        _ = walk.linebreak(held.token_start, min, null, section);
        state.previous = token;

        try walk.visit(child, state.depth + 1);

        return .yielded;
    }

    fn gen_decl_resume(walk: *Walk, state: *GenDecl) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .gen_decl);
        assert(state.from <= state.to);

        stage: switch (state.stage) {
            .start => return walk.gen_decl_started(state),
            .specs => {
                if (state.at < state.to) {
                    try walk.gen_decl_spec(state);

                    return .yielded;
                }

                walk.keeps.truncate(state.base);
                walk.ws(.unindent);
                walk.ws(.formfeed);

                continue :stage .closed;
            },
            .closed => {
                walk.through(walk.end_of(state.node));
                walk.lists.truncate(state.from);

                return .returned;
            },
        }
    }

    fn gen_decl_started(walk: *Walk, state: *GenDecl) error{Overflow}!Resumed {
        const start = walk.start_of(state.node);
        const end = walk.end_of(state.node);
        const range = walk.listed(state.node, .all);
        const keyword = walk.kinds[start];

        assert(state.stage == .start);

        state.from = range.from;
        state.to = range.to;
        state.stage = .closed;

        const paren = walk.paren_after(start, end) orelse {
            if (range.from < range.to) {
                const spec = walk.item_at(range.from);

                walk.through(walk.start_of(spec));

                try walk.visit_spec(spec, 1, state.depth);
            }

            return .yielded;
        };

        assert(paren > start);

        walk.through(paren + 1);

        if (range.from == range.to) return .yielded;

        state.base = walk.keeps.count();

        walk.ws(.indent);
        walk.ws(.formfeed);
        state.valued = walk.gen_decl_valued(keyword, range);
        state.at = range.from;
        state.line = 0;
        state.stage = .specs;

        return .yielded;
    }

    fn gen_decl_valued(walk: *Walk, keyword: Kind, range: Range) bool {
        assert(range.from <= range.to);

        if (range.to - range.from <= 1) return false;
        assert(keyword.is_token());

        const declared = keyword == .const_keyword or keyword == .var_keyword;
        if (!declared) return false;

        walk.kept_types(range) catch return false;

        assert(walk.keeps.count() >= range.to - range.from);

        return true;
    }

    fn gen_decl_spec(walk: *Walk, state: *GenDecl) error{Overflow}!void {
        const at = state.at;
        const spec = walk.item_at(at);
        const first = walk.start_of(spec);

        assert(at < state.to);
        assert(at >= state.from);

        walk.through(first);

        if (at > state.from) {
            const section = walk.lines_from(state.line) > 0;

            _ = walk.linebreak(first, 1, null, section);
        }

        state.line = walk.lines[first];
        state.at += 1;

        if (state.valued) {
            const keep = walk.keeps.get(state.base + at - state.from);

            return walk.push_task(&.{ .value_spec = .{
                .aligned = true,
                .depth = state.depth,
                .keep = keep,
                .node = spec,
            } });
        }

        try walk.visit_spec(spec, state.to - state.from, state.depth);
    }

    fn listed_resume(walk: *Walk, state: *Listed) error{Overflow}!Resumed {
        assert(state.node < walk.tree.count());
        assert(state.from <= walk.lists.count());

        switch (state.stage) {
            .start => {
                const range = walk.listed(state.node, state.filter);

                state.from = range.from;
                state.stage = .closed;

                try walk.push_task(&expr_list_of(null, range, state.mode, null, state.depth));

                return .yielded;
            },
            .closed => {
                if (state.end) |end| walk.through(end);

                walk.lists.truncate(state.from);

                return .returned;
            },
        }
    }

    fn value_spec_resume(walk: *Walk, state: *ValueSpec) error{Overflow}!Resumed {
        assert(state.extra <= 3);
        assert(state.extra > 0);

        stage: switch (state.stage) {
            .start => {
                const parts = walk.spec_parts(state.node);

                state.typed = parts.typed;
                state.equal = parts.equal;
                state.stage = .named;

                try walk.push_task(&names_of(
                    state.node,
                    parts.names_end,
                    !state.aligned,
                    state.depth,
                ));

                return .yielded;
            },
            .named => {
                const tabbed = state.typed != null or state.keep;

                if (state.aligned) {
                    if (tabbed) {
                        walk.ws(.vtab);
                        state.extra -= 1;
                    }
                }

                state.stage = .typed;

                const typed = state.typed orelse continue :stage .typed;

                walk.through(walk.start_of(typed));

                try walk.visit(typed, state.depth + 1);

                return .yielded;
            },
            .typed => {
                state.stage = .valued;

                const equal = state.equal orelse continue :stage .valued;

                if (state.aligned) walk.ws(.vtab);

                walk.through(equal + 1);

                if (state.aligned) state.extra -= 1;

                try walk.push_task(&values_of(state.node, equal, state.depth));

                return .yielded;
            },
            .valued => {
                if (state.aligned) walk.value_spec_padded(state);

                walk.through(walk.end_of(state.node));

                return .returned;
            },
        }
    }

    fn value_spec_padded(walk: *Walk, state: *const ValueSpec) void {
        assert(state.aligned);
        assert(state.extra > 0);

        if (!walk.line_commented(walk.final_of(state.node))) return;

        for (0..state.extra) |_| {
            walk.ws(.vtab);
        }
    }

    fn spec_type_resume(walk: *Walk, state: *SpecType) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .type_spec);
        assert(state.count > 0);

        stage: switch (state.stage) {
            .start => {
                const name = walk.tree.child_first_of(state.node) orelse {
                    walk.through(walk.end_of(state.node));

                    return .returned;
                };

                walk.through(walk.start_of(name));
                state.child = walk.tree.sibling_next_of(name);
                state.stage = .named;

                try walk.visit(name, state.depth + 1);

                return .yielded;
            },
            .named => {
                state.stage = .typed;

                const child = state.child orelse continue :stage .typed;
                if (walk.tree.kind_at(child) != .field_list) continue :stage .typed;
                if (walk.kinds[walk.start_of(child)] != .bracket_open) continue :stage .typed;

                walk.through(walk.start_of(child));
                state.child = walk.tree.sibling_next_of(child);

                const parameters: Task = .{
                    .parameters = .{ .depth = state.depth + 1, .node = child },
                };

                try walk.push_task(&parameters);

                return .yielded;
            },
            .typed => {
                if (state.count > 1) walk.ws(.vtab);

                state.stage = .children;

                continue :stage .children;
            },
            .children => {
                const child = state.child orelse {
                    walk.through(walk.end_of(state.node));

                    return .returned;
                };

                walk.through(walk.start_of(child));
                state.child = walk.tree.sibling_next_of(child);

                try walk.visit(child, state.depth + 1);

                return .yielded;
            },
        }
    }

    fn func_body_resume(walk: *Walk, state: *FuncBody) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .block_stmt);
        if (state.stage != .start) assert(walk.level == 0);

        stage: switch (state.stage) {
            .start => {
                const open = walk.start_of(state.node);
                const close = walk.final_of(state.node);

                state.level = walk.level;
                walk.level = 0;

                if (walk.lines[open] != walk.ends[close]) {
                    state.stage = .closed;

                    try walk.push_task(&block_of(state.node, 1, state.depth));

                    return .yielded;
                }

                if (state.separator) |item| walk.ws(item);

                walk.through(open + 1);
                state.child = walk.tree.child_first_of(state.node);
                state.stage = .statements;

                continue :stage .statements;
            },
            .statements => {
                const child = state.child orelse {
                    const close = walk.final_of(state.node);

                    walk.through(close);
                    walk.flags[close] |= flag_no_break;

                    walk.through(close + 1);

                    continue :stage .closed;
                };

                walk.through(walk.start_of(child));
                state.child = walk.tree.sibling_next_of(child);

                try walk.visit_statement(child, false, state.depth + 1);

                return .yielded;
            },
            .closed => {
                walk.through(walk.end_of(state.node));
                walk.level = state.level;

                return .returned;
            },
        }
    }

    fn block_resume(walk: *Walk, state: *Block) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .block_stmt);
        assert(state.indent <= 1);

        switch (state.stage) {
            .start => {
                const open = walk.start_of(state.node);
                const range = walk.listed(state.node, .all);

                state.from = range.from;

                walk.through(open + 1);
                state.stage = .closed;

                try walk.push_task(&statements_of(range, state.indent, true, state.depth));

                return .yielded;
            },
            .closed => {
                const close = walk.final_of(state.node);

                walk.through(close);
                _ = walk.linebreak(close, 1, null, true);

                walk.through(walk.end_of(state.node));
                walk.lists.truncate(state.from);

                return .returned;
            },
        }
    }

    fn statements_resume(walk: *Walk, state: *Statements) error{Overflow}!Resumed {
        assert(state.from <= state.at);
        assert(state.at <= state.to);

        if (state.stage == .start) {
            if (state.indent > 0) walk.ws(.indent);

            state.stage = .items;
        }

        while (state.at < state.to) {
            const at = state.at;
            const statement = walk.item_at(at);

            state.at += 1;

            if (walk.tree.kind_at(statement) == .empty_stmt) {
                walk.through(walk.end_of(statement));

                continue;
            }

            const first = walk.start_of(statement);

            walk.through(first);

            const separated = walk.lines_from(state.line) > 0;
            const section = state.index == 0 or state.indent == 0 or separated;
            const closing = state.closing and at + 1 == state.to;

            _ = walk.linebreak(first, 1, null, section);
            state.line = walk.lines[first] + walk.labels(statement);
            state.index += 1;

            try walk.visit_statement(statement, closing, state.depth + 1);

            return .yielded;
        }

        if (state.indent > 0) walk.ws(.unindent);

        return .returned;
    }

    fn labeled_resume(walk: *Walk, state: *Labeled) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .labeled_stmt);

        if (state.stage == .start) {
            const start = walk.start_of(state.node);
            const end = walk.end_of(state.node);

            state.colon = walk.depthless(start, end, .colon) orelse start;

            walk.ws(.unindent);
            walk.through(state.colon + 1);
            walk.ws(.indent);
            state.child = walk.tree.child_first_of(state.node);
            state.stage = .children;
        }

        for (0..walk.tree.count()) |_| {
            const child = state.child orelse break;
            const held = walk.tree.at(child);

            state.child = walk.tree.sibling_next_of(child);

            if (held.token_start <= state.colon) continue;

            if (held.kind == .empty_stmt) {
                if (!state.closing) walk.ws(.newline);

                walk.through(held.token_end);

                continue;
            }

            walk.through(held.token_start);
            _ = walk.linebreak(held.token_start, 1, null, true);

            try walk.visit_statement(child, state.closing, state.depth + 1);

            return .yielded;
        }

        assert(state.child == null);

        walk.through(walk.end_of(state.node));

        return .returned;
    }

    fn if_stmt_resume(walk: *Walk, state: *IfStmt) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .if_stmt);
        assert(state.tail >= walk.start_of(state.node));

        const child = state.child orelse {
            walk.through(walk.end_of(state.node));
            walk.through(state.tail);

            return .returned;
        };

        const held = walk.tree.at(child);
        const sibling = walk.tree.sibling_next_of(child);
        const depth = state.depth + 1;

        state.child = sibling;

        walk.through(held.token_start);

        if (held.kind == .block_stmt) {
            if (!state.bodied) {
                state.bodied = true;

                try walk.push_task(&block_of(child, 1, depth));

                return .yielded;
            }
        }

        if (state.bodied) {
            if (held.kind == .if_stmt) return walk.if_stmt_chained(state, child, sibling);

            if (held.kind == .block_stmt) {
                try walk.push_task(&block_of(child, 1, depth));

                return .yielded;
            }
        }

        try walk.visit(child, depth);

        return .yielded;
    }

    fn if_stmt_chained(
        walk: *Walk,
        state: *IfStmt,
        child: u32,
        sibling: ?u32,
    ) error{Overflow}!Resumed {
        assert(state.bodied);
        assert(walk.tree.kind_at(child) == .if_stmt);
        if (sibling) |held| assert(held < std.math.maxInt(u32));

        if (sibling != null) {
            try walk.push_task(&walk.if_stmt_of(child, state.depth + 1));

            return .yielded;
        }

        state.bodied = false;
        state.child = walk.tree.child_first_of(child);
        state.depth += 1;
        state.node = child;

        return .yielded;
    }

    fn clause_resume(walk: *Walk, state: *Clause) error{Overflow}!Resumed {
        assert(state.from <= state.to);
        assert(state.split <= state.to);

        stage: switch (state.stage) {
            .start => return walk.clause_started(state),
            .comm => {
                if (state.at < state.split) {
                    const held = walk.item_at(state.at);

                    state.at += 1;

                    walk.through(walk.start_of(held));

                    try walk.visit(held, state.depth + 1);

                    return .yielded;
                }

                continue :stage .listed;
            },
            .listed => {
                const range: Range = .{ .from = state.split, .to = state.to };

                walk.through(state.colon + 1);
                state.stage = .closed;

                try walk.push_task(&statements_of(range, 1, state.closing, state.depth));

                return .yielded;
            },
            .closed => {
                walk.through(walk.end_of(state.node));
                walk.lists.truncate(state.from);

                return .returned;
            },
        }
    }

    fn clause_started(walk: *Walk, state: *Clause) error{Overflow}!Resumed {
        const start = walk.start_of(state.node);
        const end = walk.end_of(state.node);
        const colon = walk.depthless(start, end, .colon) orelse start;
        const comm = walk.tree.kind_at(state.node) == .comm_clause;
        const range = walk.listed(state.node, .all);

        assert(state.stage == .start);

        state.colon = colon;
        state.from = range.from;
        state.to = range.to;
        state.split = walk.split_after(range, colon);
        state.at = range.from;
        state.stage = .listed;

        assert(state.split >= range.from);

        if (comm) {
            state.stage = .comm;

            return .yielded;
        }

        if (range.from == state.split) return .yielded;

        const listed_range: Range = .{ .from = range.from, .to = state.split };

        walk.through(walk.start_of(walk.item_at(range.from)));

        try walk.push_task(&expr_list_of(start, listed_range, 0, colon, state.depth));

        return .yielded;
    }

    fn return_stmt_resume(walk: *Walk, state: *ReturnStmt) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .return_stmt);
        assert(state.from <= walk.lists.count());

        stage: switch (state.stage) {
            .start => {
                const range = walk.listed(state.node, .all);

                state.from = range.from;
                state.stage = .listed;

                if (range.from == range.to) continue :stage .listed;

                walk.through(walk.start_of(walk.item_at(range.from)));
                state.indented = walk.indent_list(range);

                if (state.indented) walk.ws(.indent);

                const mode: u8 = if (state.indented) no_indent else 0;

                try walk.push_task(&expr_list_of(null, range, mode, null, state.depth));

                return .yielded;
            },
            .listed => {
                if (state.indented) walk.ws(.unindent);

                walk.through(walk.end_of(state.node));
                walk.lists.truncate(state.from);

                return .returned;
            },
        }
    }

    fn assign_resume(walk: *Walk, state: *Assign) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .assign_stmt);
        assert(state.split <= state.to);

        switch (state.stage) {
            .start => {
                const start = walk.start_of(state.node);
                const end = walk.end_of(state.node);

                const operator = walk.assigning(start, end) orelse {
                    return walk.replaced(&walk.children_of(state.node, .generic, state.depth));
                };

                const range = walk.listed(state.node, .all);

                state.operator = operator;
                state.from = range.from;
                state.to = range.to;
                state.split = walk.split_after(range, operator);
                state.stage = .left;

                const left: Range = .{ .from = range.from, .to = state.split };

                try walk.push_task(&expr_list_of(start, left, 0, operator, state.depth));

                return .yielded;
            },
            .left => {
                const right: Range = .{ .from = state.split, .to = state.to };

                walk.through(state.operator + 1);

                if (state.split < state.to) walk.through(walk.start_of(walk.item_at(state.split)));

                state.stage = .right;

                try walk.push_task(&expr_list_of(state.operator, right, 0, null, state.depth));

                return .yielded;
            },
            .right => {
                walk.through(walk.end_of(state.node));
                walk.lists.truncate(state.from);

                return .returned;
            },
        }
    }

    fn binary_resume(walk: *Walk, state: *Binary) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .binary_expr);
        assert(state.from <= state.at);

        stage: switch (state.stage) {
            .start => return walk.binary_started(state),
            .operands => {
                state.stage = .operands;

                while (state.at > state.from) {
                    state.at -= 1;

                    const expression = walk.item_at(state.at);
                    const pair = walk.operands(expression) orelse continue;
                    const right_start = walk.start_of(pair.right);

                    walk.through(right_start);
                    state.expression = expression;
                    state.unindent = walk.binary_broken(right_start);
                    state.stage = .right;

                    try walk.visit(pair.right, state.depth + 1);

                    return .yielded;
                }

                walk.lists.truncate(state.from);

                return .returned;
            },
            .right => {
                if (state.unindent) walk.ws(.unindent);

                walk.through(walk.end_of(state.expression));

                continue :stage .operands;
            },
        }
    }

    fn binary_started(walk: *Walk, state: *Binary) error{Overflow}!Resumed {
        const range = walk.binary_spine(state.node);
        const pair = if (range.from < range.to) walk.operands(walk.item_at(range.to - 1)) else null;

        assert(state.stage == .start);

        const left = (pair orelse {
            walk.lists.truncate(range.from);

            return walk.replaced(&walk.children_of(state.node, .generic, state.depth));
        }).left;

        assert(left > state.node);

        state.from = range.from;
        state.at = range.to;
        state.stage = .operands;

        walk.through(walk.start_of(left));

        try walk.visit(left, state.depth + 1);

        return .yielded;
    }

    fn binary_spine(walk: *Walk, node: u32) Range {
        assert(node < std.math.maxInt(u32));

        const from = walk.lists.count();
        var held = node;

        assert(walk.tree.kind_at(node) == .binary_expr);

        for (0..walk.tree.count()) |_| {
            const pair = walk.operands(held) orelse break;

            if (walk.lists.full()) break;

            walk.lists.push(held);

            if (walk.operands(pair.left) == null) break;

            held = pair.left;
        }

        assert(walk.lists.count() >= from);

        return .{ .from = from, .to = walk.lists.count() };
    }

    fn binary_broken(walk: *Walk, right_start: u32) bool {
        assert(right_start < walk.lines.len);
        assert(walk.lines.len == walk.ends.len);

        if (!walk.broken_at(right_start)) return false;
        return walk.linebreak(right_start, 1, .indent, true) > 0;
    }

    fn selector_resume(walk: *Walk, state: *Selector) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .selector_expr);
        if (state.stage == .operand) assert(state.name > state.node);

        switch (state.stage) {
            .start => {
                const parts = walk.selector_parts(state.node) orelse {
                    state.stage = .fallback;

                    try walk.push_task(&walk.children_of(state.node, .generic, state.depth));

                    return .yielded;
                };

                state.name = parts.right;
                state.stage = .operand;

                walk.through(walk.start_of(parts.left));

                try walk.visit(parts.left, state.depth + 1);

                return .yielded;
            },
            .operand => {
                const first = walk.start_of(state.name);

                walk.through(first);
                state.broken = walk.broken_at(first);

                if (state.broken) {
                    walk.ws(.indent);
                    walk.ws(.newline);
                }

                state.stage = .named;

                try walk.visit(state.name, state.depth + 1);

                return .yielded;
            },
            .named => {
                if (state.broken) {
                    if (!state.method) walk.ws(.unindent);
                }

                walk.through(walk.end_of(state.node));
                walk.selected = state.broken and state.method;

                return .returned;
            },
            .fallback => {
                walk.selected = false;

                return .returned;
            },
        }
    }

    fn selector_parts(walk: *const Walk, node: u32) ?Operands {
        assert(node < std.math.maxInt(u32));

        const operand = walk.tree.child_first_of(node) orelse return null;
        const name = walk.tree.sibling_next_of(operand) orelse return null;
        if (walk.tree.sibling_next_of(name) != null) return null;

        assert(operand > node);
        assert(name > operand);

        return .{ .left = operand, .right = name };
    }

    fn call_resume(walk: *Walk, state: *Call) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .call_expr);
        assert(state.from <= walk.lists.count());

        stage: switch (state.stage) {
            .start => return walk.call_started(state),
            .callee => {
                const close = walk.final_of(state.node);

                state.indented = if (state.selecting) walk.selected else false;

                walk.through(state.open + 1);

                const range = walk.listed(state.node, .{ .other_than = state.callee });

                state.from = range.from;

                if (walk.ellipsis(state.open, close)) |dots| {
                    state.dots = dots;
                    state.stage = .dotted;

                    try walk.push_task(&expr_list_of(state.open, range, 0, dots, state.depth));

                    return .yielded;
                }

                state.stage = .closed;

                const mode = comma_term;

                try walk.push_task(&expr_list_of(state.open, range, mode, close, state.depth));

                return .yielded;
            },
            .dotted => {
                const close = walk.final_of(state.node);

                walk.through(state.dots + 1);

                if (walk.lines[close] > walk.lines[state.dots]) {
                    walk.through(close);
                    walk.ws(.formfeed);
                }

                continue :stage .closed;
            },
            .closed => {
                walk.lists.truncate(state.from);
                walk.through(walk.final_of(state.node) + 1);

                if (state.indented) walk.ws(.unindent);

                walk.through(walk.end_of(state.node));

                return .returned;
            },
        }
    }

    fn call_started(walk: *Walk, state: *Call) error{Overflow}!Resumed {
        const start = walk.start_of(state.node);
        const end = walk.end_of(state.node);
        const generic = walk.children_of(state.node, .generic, state.depth);
        const callee = walk.tree.child_first_of(state.node) orelse return walk.replaced(&generic);
        const open = walk.code_from(walk.end_of(callee), end) orelse start;

        assert(state.stage == .start);
        assert(callee > state.node);

        if (walk.kinds[open] != .paren_open) return walk.replaced(&generic);

        state.callee = callee;
        state.open = open;
        state.stage = .callee;

        if (walk.tree.kind_at(callee) == .selector_expr) {
            state.selecting = true;

            try walk.push_task(&.{ .selector = .{
                .depth = state.depth + 1,
                .method = true,
                .node = callee,
            } });

            return .yielded;
        }

        try walk.visit(callee, state.depth + 1);

        return .yielded;
    }

    fn ellipsis(walk: *const Walk, open: u32, close: u32) ?u32 {
        assert(open <= close);
        assert(close < walk.kinds.len);

        const held = walk.code_before(close) orelse return null;

        const before = if (walk.kinds[held] == .comma) walk.code_before(held) orelse {
            return null;
        } else held;

        if (walk.kinds[before] != .dot_dot_dot) return null;
        if (before <= open) return null;
        return before;
    }

    fn composite_resume(walk: *Walk, state: *Composite) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .composite_lit);
        assert(state.from <= state.to);

        stage: switch (state.stage) {
            .start => {
                const start = walk.start_of(state.node);
                const head = walk.tree.child_first_of(state.node);
                const typed = head != null and walk.kinds[start] != .brace_open;
                const head_typed: ?u32 = if (typed) head else null;

                state.open = walk.composite_open(state.node, head_typed) orelse {
                    return walk.replaced(&walk.children_of(state.node, .generic, state.depth));
                };

                state.stage = .head;

                const held = head_typed orelse continue :stage .head;

                walk.through(walk.start_of(held));

                try walk.visit(held, state.depth + 1);

                return .yielded;
            },
            .head => {
                const close = walk.final_of(state.node);

                walk.level += 1;

                walk.through(state.open + 1);

                const range = walk.listed(state.node, .{ .starts_after = state.open });
                const mode = comma_term;

                state.from = range.from;
                state.to = range.to;
                state.stage = .listed;

                try walk.push_task(&expr_list_of(state.open, range, mode, close, state.depth));

                return .yielded;
            },
            .listed => {
                walk.composite_closed(state);

                return .returned;
            },
        }
    }

    fn composite_open(walk: *const Walk, node: u32, head: ?u32) ?u32 {
        assert(node < std.math.maxInt(u32));
        if (head) |held| assert(held < std.math.maxInt(u32));

        const start = walk.start_of(node);
        const end = walk.end_of(node);
        const opener = if (head) |held| walk.code_from(walk.end_of(held), end) else start;
        const open = opener orelse return null;

        assert(open >= start);
        assert(open < walk.kinds.len);

        if (walk.kinds[open] != .brace_open) return null;
        return open;
    }

    fn composite_closed(walk: *Walk, state: *const Composite) void {
        const close = walk.final_of(state.node);
        const empty = state.from == state.to;
        const mode: u8 = if (empty) flag_no_break else flag_no_break | flag_no_blank;

        assert(state.stage == .listed);
        assert(walk.level > 0);

        walk.lists.truncate(state.from);
        walk.through(close);
        walk.ws(.indent);
        walk.ws(.unindent);
        walk.flags[close] |= mode;

        walk.through(close + 1);
        walk.level -= 1;

        walk.through(walk.end_of(state.node));
    }

    fn index_list_resume(walk: *Walk, state: *IndexList) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .index_list_expr);
        assert(state.from <= walk.lists.count());

        switch (state.stage) {
            .start => {
                const operand = walk.tree.child_first_of(state.node) orelse {
                    return walk.replaced(&walk.children_of(state.node, .generic, state.depth));
                };

                state.operand = operand;
                state.stage = .operand;

                walk.through(walk.start_of(operand));

                try walk.visit(operand, state.depth + 1);

                return .yielded;
            },
            .operand => {
                const end = walk.end_of(state.node);
                const close = walk.final_of(state.node);
                const open = walk.code_from(walk.end_of(state.operand), end) orelse close;

                walk.through(open + 1);

                const range = walk.listed(state.node, .{ .other_than = state.operand });
                const mode = comma_term;

                state.from = range.from;
                state.stage = .listed;

                try walk.push_task(&expr_list_of(open, range, mode, close, state.depth + 1));

                return .yielded;
            },
            .listed => {
                walk.lists.truncate(state.from);
                walk.through(walk.end_of(state.node));

                return .returned;
            },
        }
    }

    fn expr_list_resume(walk: *Walk, state: *ExprList) error{Overflow}!Resumed {
        assert(state.at <= state.to);
        assert(state.count <= state.to - state.from);

        stage: switch (state.stage) {
            .start => {
                if (state.from >= state.to) return .returned;
                if (walk.expr_list_started(state)) continue :stage .elements;

                state.at = state.from;

                continue :stage .inlined;
            },
            .inlined => {
                state.stage = .inlined;

                if (state.at == state.to) return .returned;

                const element = walk.item_at(state.at);

                state.at += 1;

                walk.through(walk.start_of(element));

                try walk.visit(element, state.depth + 1);

                return .yielded;
            },
            .elements => {
                state.stage = .elements;

                if (state.at < state.to) {
                    try walk.expr_list_element(state);

                    return .yielded;
                }

                walk.expr_list_closed(state);

                return .returned;
            },
            .keyed => {
                state.stage = .valued;

                const value = walk.tree.sibling_next_of(state.key) orelse continue :stage .valued;

                try walk.expr_list_value(state, value);

                return .yielded;
            },
            .valued => {
                walk.through(walk.end_of(state.element));

                continue :stage .finished;
            },
            .finished => {
                if (state.size > 0) {
                    state.sum += go_log(@floatFromInt(state.size));
                    state.count += 1;
                }

                state.line_previous = state.line;
                state.at += 1;

                continue :stage .elements;
            },
        }
    }

    fn expr_list_value(walk: *Walk, state: *const ExprList, value: u32) error{Overflow}!void {
        assert(value > state.key);

        const start = walk.start_of(value);
        const colon = walk.depthless(walk.end_of(state.key), start, .colon);

        assert(state.stage == .valued);

        walk.through(if (colon) |held| held + 1 else start);
        walk.ws(.vtab);
        walk.through(start);

        try walk.visit(value, state.depth + 1);
    }

    fn expr_list_started(walk: *Walk, state: *ExprList) bool {
        const head = walk.item_at(state.from);
        const tail = walk.item_at(state.to - 1);
        const previous: ?u32 = if (state.before) |at| walk.lines[at] else null;
        const line_first = walk.lines[walk.start_of(head)];
        const line_end = walk.ends[walk.final_of(tail)];
        const joined = if (previous) |line| line == line_first else false;

        assert(state.from < state.to);
        assert(state.stage == .start);

        if (joined) {
            if (line_first == line_end) return false;
        }

        state.ws = if ((state.mode & no_indent) == 0) .indent else null;
        state.break_previous = -1;

        walk.through(walk.start_of(head));

        const opened = if (previous) |line| line < line_first else false;

        if (opened) {
            if (walk.linebreak(walk.start_of(head), 0, state.ws, true) > 0) {
                state.ws = null;
                state.break_previous = 0;
            }
        }

        state.size = 0;
        state.sum = 0.0;
        state.count = 0;
        state.line_previous = previous orelse 0;
        state.at = state.from;

        return true;
    }

    fn expr_list_element(walk: *Walk, state: *ExprList) error{Overflow}!void {
        const index = state.at - state.from;
        const element = walk.item_at(state.at);
        const first = walk.start_of(element);
        const line = walk.lines[first];
        const size_previous = state.size;
        const pair = walk.tree.kind_at(element) == .key_value_expr;
        const key = walk.tree.child_first_of(element);

        assert(state.at < state.to);
        assert(state.stage == .elements);

        state.size = walk.expr_list_size(state, element, pair, key);

        const formfeed = expr_list_formfeed(state, size_previous);
        const needs = 0 < state.line_previous and state.line_previous < line;

        walk.through(first);

        if (index > 0) {
            if (needs) walk.expr_list_break(state, first, index, formfeed);
        }

        state.element = element;
        state.line = line;
        state.stage = .finished;

        const many = state.to - state.from > 1;
        const keyed = many and pair and state.size > 0 and needs;

        if (keyed) {
            if (key) |held| {
                state.key = held;
                state.stage = .keyed;

                return walk.visit(held, state.depth + 1);
            }
        }

        try walk.visit(element, state.depth + 1);
    }

    fn expr_list_size(
        walk: *const Walk,
        state: *const ExprList,
        element: u32,
        pair: bool,
        key: ?u32,
    ) u32 {
        assert(element < walk.tree.count());
        if (key) |held| assert(held < std.math.maxInt(u32));

        const width = walk.size_of(element) orelse return 0;

        if (state.before == null) return 0;
        if (state.after == null) return 0;
        if (!pair) return width;

        const held = key orelse return width;

        assert(held > element);

        return walk.size_of(held) orelse 0;
    }

    fn expr_list_break(walk: *Walk, state: *ExprList, first: u32, index: u32, formfeed: bool) void {
        assert(first < std.math.maxInt(u32));
        assert(index > 0);

        const section = formfeed or state.break_previous + 1 < @as(i64, index);
        const breaks = walk.linebreak(first, 0, state.ws, section);

        assert(breaks <= 3);

        if (breaks > 0) {
            state.ws = null;
            state.break_previous = index;
        }

        if (breaks > 1) {
            state.sum = 0.0;
            state.count = 0;
        }
    }

    fn expr_list_closed(walk: *Walk, state: *const ExprList) void {
        const unindented = state.ws == null and (state.mode & no_indent) == 0;
        const closed = walk.expr_list_closer(state.after);

        assert(state.at == state.to);
        assert(state.from < state.to);

        if ((state.mode & comma_term) != 0) {
            if (closed) {
                if (state.after) |at| walk.through(at);
                if (unindented) walk.ws(.unindent);

                walk.ws(.formfeed);

                return;
            }
        }

        if (unindented) walk.ws(.unindent);
    }

    fn expr_list_closer(walk: *const Walk, after: ?u32) bool {
        if (after) |held| assert(held < std.math.maxInt(u32));

        const at = after orelse return false;
        const last = walk.last orelse return false;

        assert(at < walk.lines.len);
        assert(last < walk.ends.len);

        return walk.ends[last] < walk.lines[at];
    }

    fn parameters_resume(walk: *Walk, state: *Parameters) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .field_list);
        if (state.stage == .fields) assert(state.line_previous > 0);

        stage: switch (state.stage) {
            .start => {
                const open = walk.start_of(state.node);

                walk.through(open + 1);
                state.parameter = walk.tree.child_first_of(state.node);

                if (state.parameter == null) continue :stage .closed;

                state.line_previous = walk.lines[open];
                state.ws = .indent;
                state.stage = .fields;

                continue :stage .fields;
            },
            .fields => {
                const parameter = state.parameter orelse {
                    walk.parameters_closed(state);

                    continue :stage .closed;
                };

                try walk.parameters_field(state, parameter);

                return .yielded;
            },
            .closed => {
                walk.through(walk.final_of(state.node) + 1);
                walk.through(walk.end_of(state.node));

                return .returned;
            },
        }
    }

    fn parameters_field(walk: *Walk, state: *Parameters, parameter: u32) error{Overflow}!void {
        assert(parameter < std.math.maxInt(u32));

        const first = walk.start_of(parameter);
        const line_start = walk.lines[first];
        const line_end = walk.ends[walk.final_of(parameter)];
        const needs = 0 < state.line_previous and state.line_previous < line_start;

        assert(parameter > state.node);
        assert(state.stage == .fields);

        walk.through(first);

        if (needs) {
            if (walk.linebreak(first, 0, state.ws, true) > 0) state.ws = null;
        }

        const indent = if (state.ws) |item| item == .indent else false;

        state.line_previous = line_end;
        state.parameter = walk.tree.sibling_next_of(parameter);

        try walk.push_task(&.{ .field = .{
            .depth = state.depth,
            .indent = indent,
            .node = parameter,
        } });
    }

    fn parameters_closed(walk: *Walk, state: *const Parameters) void {
        const close = walk.final_of(state.node);

        assert(state.parameter == null);
        assert(state.stage == .fields);

        if (walk.lines[close] > state.line_previous) {
            walk.through(close);
            _ = walk.linebreak(close, 0, null, true);
        }

        if (state.ws == null) walk.ws(.unindent);
    }

    fn field_resume(walk: *Walk, state: *Field) error{Overflow}!Resumed {
        assert(state.node < walk.tree.count());
        assert(walk.tree.parent_of(state.node) != null);

        stage: switch (state.stage) {
            .start => {
                var last = walk.tree.child_first_of(state.node);
                var before: ?u32 = null;

                for (0..walk.tree.count()) |_| {
                    const held = last orelse break;
                    const sibling = walk.tree.sibling_next_of(held) orelse break;

                    before = held;
                    last = sibling;
                }

                state.child_last = last;
                state.stage = .named;

                const named = before orelse continue :stage .named;
                const names_end = walk.end_of(named);

                try walk.push_task(&names_of(state.node, names_end, state.indent, state.depth));

                return .yielded;
            },
            .named => {
                state.stage = .typed;

                const last = state.child_last orelse continue :stage .typed;

                walk.through(walk.start_of(last));

                try walk.visit(last, state.depth + 1);

                return .yielded;
            },
            .typed => {
                walk.through(walk.end_of(state.node));

                return .returned;
            },
        }
    }

    fn field_list_resume(walk: *Walk, state: *FieldList) error{Overflow}!Resumed {
        assert(walk.tree.kind_at(state.node) == .field_list);
        assert(state.from <= state.to);

        if (state.stage == .start) {
            if (walk.field_list_started(state)) |task| return walk.replaced(&task);
        }

        if (state.at < state.to) {
            const at = state.at;
            const field = walk.item_at(at);
            const first = walk.start_of(field);

            walk.through(first);

            if (at > state.from) {
                const section = walk.lines_from(state.line) > 0;

                _ = walk.linebreak(first, 1, null, section);
            }

            state.line = walk.lines[first];
            state.at += 1;

            const task: Task = if (state.structured) .{ .struct_field = .{
                .depth = state.depth,
                .node = field,
                .separator = state.separator,
            } } else walk.children_of(field, .interface_field, state.depth);

            try walk.push_task(&task);

            return .yielded;
        }

        walk.lists.truncate(state.from);
        walk.ws(.unindent);
        walk.ws(.formfeed);
        walk.through(walk.final_of(state.node) + 1);
        walk.through(walk.end_of(state.node));

        return .returned;
    }

    fn field_list_started(walk: *Walk, state: *FieldList) ?Task {
        const open = walk.start_of(state.node);
        const close = walk.final_of(state.node);
        const opener = walk.kinds[open];
        const generic = walk.children_of(state.node, .generic, state.depth);

        assert(state.stage == .start);
        assert(open <= close);

        if (walk.bracketed(open)) {
            return .{ .parameters = .{ .depth = state.depth, .node = state.node } };
        }

        const parent = walk.tree.parent_of(state.node) orelse return generic;
        const parent_kind = walk.tree.kind_at(parent);
        const braced = opener == .brace_open;
        const structured = braced and parent_kind == .struct_type;
        const interfaced = braced and parent_kind == .interface_type;
        const typed = structured or interfaced;
        if (!typed) return generic;
        if (walk.lines[open] == walk.ends[close]) return generic;

        const range = walk.listed(state.node, .all);
        const commented = walk.comment_within(walk.start_of(parent), close);
        const formfed = commented or range.from < range.to;

        walk.through(open + 1);
        walk.ws(.indent);

        if (formfed) walk.ws(.formfeed);

        state.from = range.from;
        state.to = range.to;
        state.at = range.from;
        state.line = 0;
        state.structured = structured;
        state.separator = if (range.to - range.from > 1) .vtab else null;
        state.stage = .fields;

        return null;
    }

    fn struct_field_resume(walk: *Walk, state: *StructField) error{Overflow}!Resumed {
        assert(state.node < walk.tree.count());
        assert(state.from <= walk.lists.count());

        stage: switch (state.stage) {
            .start => {
                const range = walk.listed(state.node, .all);
                const listed_count = range.to - range.from;
                const tagged = listed_count >= 2 and walk.tag_literal(walk.item_at(range.to - 1));
                const count = if (tagged) listed_count - 1 else listed_count;

                state.from = range.from;
                state.count = count;
                state.tag = if (tagged) walk.item_at(range.from + count) else null;
                state.named = count >= 2;

                if (state.named) {
                    const names_end = walk.end_of(walk.item_at(range.from + count - 2));

                    state.stage = .named;

                    try walk.push_task(&names_of(state.node, names_end, false, state.depth));

                    return .yielded;
                }

                state.stage = .typed;

                if (count != 1) continue :stage .typed;

                const typed = walk.item_at(range.from);

                walk.through(walk.start_of(typed));

                try walk.visit(typed, state.depth + 1);

                return .yielded;
            },
            .named => {
                const typed = walk.item_at(state.from + state.count - 1);

                if (state.separator) |item| walk.ws(item);

                walk.through(walk.start_of(typed));
                state.stage = .typed;

                try walk.visit(typed, state.depth + 1);

                return .yielded;
            },
            .typed => {
                walk.struct_field_closed(state);

                return .returned;
            },
        }
    }

    fn struct_field_closed(walk: *Walk, state: *const StructField) void {
        var extra: u32 = if (state.named) 1 else 2;

        assert(state.stage == .typed);
        assert(walk.lists.count() >= state.from);

        walk.lists.truncate(state.from);

        if (state.tag) |tag| {
            if (state.separator) |item| {
                if (state.named) walk.ws(item);

                walk.ws(item);
            }

            walk.through(walk.end_of(tag));
            extra = 0;
        }

        if (walk.line_commented(walk.final_of(state.node))) {
            if (state.separator) |item| {
                for (0..extra) |_| {
                    walk.ws(item);
                }
            }
        }

        walk.through(walk.end_of(state.node));
    }

    fn through(walk: *Walk, end: u32) void {
        assert(end < std.math.maxInt(u32));

        const bound = @min(end, @as(u32, @intCast(walk.kinds.len)));

        assert(walk.next <= walk.kinds.len);

        while (walk.next < bound) : (walk.next += 1) {
            const at = walk.next;
            if (!coded(walk.kinds[at])) continue;

            walk.gaps[at] = walk.pending;
            walk.pending = gap_empty;

            if (walk.level > 0) walk.flags[at] |= flag_level;

            walk.last = at;
        }

        assert(walk.next >= bound);
    }

    fn ws(walk: *Walk, item: Item) void {
        assert(walk.pending.count <= gap_items_max);

        walk.pending.push(item);

        assert(walk.pending.count > 0);
    }

    fn start_of(walk: *const Walk, node: u32) u32 {
        assert(node < std.math.maxInt(u32));

        const held = walk.tree.at(node);

        assert(held.token_start <= held.token_end);
        assert(held.token_start <= walk.kinds.len);

        return held.token_start;
    }

    fn end_of(walk: *const Walk, node: u32) u32 {
        assert(node < std.math.maxInt(u32));

        const held = walk.tree.at(node);

        assert(held.token_start <= held.token_end);
        assert(held.token_end <= walk.kinds.len);

        return held.token_end;
    }

    fn item_at(walk: *const Walk, at: u32) u32 {
        assert(at < walk.lists.count());

        const node = walk.lists.get(at);

        assert(node < walk.tree.count());

        return node;
    }

    fn final_of(walk: *const Walk, node: u32) u32 {
        assert(node < std.math.maxInt(u32));

        const start = walk.start_of(node);
        var at = walk.end_of(node);

        assert(at <= walk.kinds.len);

        while (at > start) {
            at -= 1;

            if (coded(walk.kinds[at])) return at;
        }

        assert(at == start);

        return start;
    }

    fn code_from(walk: *const Walk, from: u32, to: u32) ?u32 {
        assert(from < std.math.maxInt(u32));

        var at = from;

        assert(to <= walk.kinds.len);

        while (at < to) : (at += 1) {
            if (coded(walk.kinds[at])) return at;
        }

        assert(at >= to);

        return null;
    }

    fn code_before(walk: *const Walk, at: u32) ?u32 {
        assert(at <= walk.kinds.len);

        var held = at;

        while (held > 0) {
            held -= 1;

            if (coded(walk.kinds[held])) return held;
        }

        assert(held == 0);

        return null;
    }

    fn depthless(walk: *const Walk, from: u32, to: u32, wanted: Kind) ?u32 {
        assert(from < std.math.maxInt(u32));

        var depth: u32 = 0;
        var at = from;

        assert(wanted.is_token());
        assert(to <= walk.kinds.len);

        while (at < to) : (at += 1) {
            const kind = walk.kinds[at];

            if (depth == 0) {
                if (kind == wanted) return at;
            }

            switch (kind) {
                .brace_open, .bracket_open, .paren_open => depth += 1,
                .brace_close, .bracket_close, .paren_close => depth -|= 1,
                else => {},
            }
        }

        return null;
    }

    fn assigning(walk: *const Walk, from: u32, to: u32) ?u32 {
        assert(from <= to);

        var depth: u32 = 0;
        var at = from;

        assert(to <= walk.kinds.len);

        while (at < to) : (at += 1) {
            switch (walk.kinds[at]) {
                .brace_open, .bracket_open, .paren_open => depth += 1,
                .brace_close, .bracket_close, .paren_close => depth -|= 1,
                .equal,
                .colon_equal,
                .plus_equal,
                .minus_equal,
                .star_equal,
                .slash_equal,
                .percent_equal,
                .ampersand_equal,
                .bar_equal,
                .caret_equal,
                .less_less_equal,
                .greater_greater_equal,
                .ampersand_caret_equal,
                => if (depth == 0) return at,
                else => {},
            }
        }

        return null;
    }

    fn lines_from(walk: *const Walk, line: u32) u32 {
        const last = walk.last orelse return 0;

        assert(last < walk.ends.len);
        assert(walk.ends.len == walk.lines.len);

        return walk.ends[last] -| line;
    }

    fn linebreak(walk: *Walk, target: u32, min: u32, item: ?Item, section: bool) u32 {
        assert(target < walk.lines.len);
        assert(min <= 2);
        if (item) |value| assert(value == .indent);

        const line = walk.lines[target];
        const held: u32 = if (walk.last) |last| @min(line -| walk.ends[last], 2) else 0;
        var count = @max(held, min);

        assert(held <= 2);

        if (count == 0) return 0;

        if (item) |value| walk.ws(value);

        var breaks: u32 = 0;

        if (section) {
            walk.ws(.formfeed);
            count -= 1;
            breaks = 2;
        }

        breaks += count;

        for (0..count) |_| {
            walk.ws(.newline);
        }

        return breaks;
    }

    fn size_of(walk: *const Walk, node: u32) ?u32 {
        assert(node < std.math.maxInt(u32));

        const first = walk.start_of(node);
        const last = walk.final_of(node);

        assert(first <= last);

        if (walk.lines[first] != walk.ends[last]) return null;

        var width = walk.tokens[last].end() - walk.tokens[first].offset;

        for (first..last) |at| {
            if (walk.kinds[at] == .comment) width -|= walk.tokens[at].length + 1;
        }

        assert(width <= walk.tokens[last].end());

        return width;
    }

    fn labels(walk: *const Walk, node: u32) u32 {
        assert(node < std.math.maxInt(u32));

        var held = node;
        var count: u32 = 0;

        while (count < depth_max) {
            if (walk.tree.kind_at(held) != .labeled_stmt) break;

            var child = walk.tree.child_first_of(held);
            var inner: ?u32 = null;

            for (0..walk.tree.count()) |_| {
                const at = child orelse break;

                if (walk.tree.kind_at(at) != .ident) inner = at;

                child = walk.tree.sibling_next_of(at);
            }

            count += 1;
            held = inner orelse break;
        }

        assert(count <= depth_max);
        if (count > 0) assert(walk.tree.kind_at(node) == .labeled_stmt);

        return count;
    }

    fn spec_parts(walk: *const Walk, spec: u32) Parts {
        assert(spec < std.math.maxInt(u32));

        const start = walk.start_of(spec);
        const equal = walk.depthless(start, walk.end_of(spec), .equal);
        var names_end = start;
        var typed: ?u32 = null;
        var child = walk.tree.child_first_of(spec);
        var first = true;

        for (0..walk.tree.count()) |_| {
            const held = child orelse break;
            const node = walk.tree.at(held);

            if (equal) |at| {
                if (node.token_start > at) break;
            }

            const before = walk.code_before(node.token_start);
            const comma = if (before) |at| walk.kinds[at] == .comma else false;
            const named = node.kind == .ident and (first or comma) and typed == null;

            if (named) {
                names_end = node.token_end;
            } else {
                typed = held;
            }

            first = false;
            child = walk.tree.sibling_next_of(held);
        }

        assert(names_end >= start);
        if (equal) |at| assert(at >= start);

        return .{ .equal = equal, .names_end = names_end, .typed = typed };
    }

    fn kept_types(walk: *Walk, range: Range) error{Overflow}!void {
        const base = walk.keeps.count();

        assert(range.to - range.from > 1);

        for (range.from..range.to) |_| {
            if (walk.keeps.full()) return error.Overflow;

            walk.keeps.push(false);
        }

        const keeps = walk.keeps.slice();
        var start: ?u32 = null;
        var keep = false;

        for (range.from..range.to) |position| {
            const at: u32 = @intCast(position);
            const parts = walk.spec_parts(walk.item_at(at));

            if (parts.equal != null) {
                if (start == null) {
                    start = at;
                    keep = false;
                }
            } else if (start) |held| {
                @memset(keeps[base + held - range.from .. base + at - range.from], keep);
                start = null;
            } else {}

            if (parts.typed != null) keep = true;
        }

        if (start) |held| {
            @memset(keeps[base + held - range.from .. base + range.to - range.from], keep);
        }

        assert(walk.keeps.count() == base + range.to - range.from);
    }

    fn line_commented(walk: *const Walk, last: u32) bool {
        assert(last < walk.ends.len);

        const count: u32 = @intCast(walk.kinds.len);
        var at = last + 1;
        var line = walk.ends[last];
        var found = false;

        assert(last < count);

        while (at < count) : (at += 1) {
            switch (walk.kinds[at]) {
                .newline => {},
                .comment => {
                    if (walk.lines[at] != line) break;

                    found = true;
                    line = walk.ends[at];
                },
                else => return found and walk.lines[at] > line,
            }
        }

        assert(line >= walk.ends[last]);

        return found;
    }

    fn indent_list(walk: *const Walk, range: Range) bool {
        assert(range.from < range.to);

        if (range.to - range.from < 2) return false;

        const first = walk.lines[walk.start_of(walk.item_at(range.from))];
        const last = walk.ends[walk.final_of(walk.item_at(range.to - 1))];
        if (first >= last) return false;

        var spread: u32 = 0;
        var line = first;

        for (range.from..range.to) |position| {
            const held = walk.item_at(@intCast(position));
            const start = walk.lines[walk.start_of(held)];
            const end = walk.ends[walk.final_of(held)];

            if (line < start) return true;

            if (start < end) spread += 1;

            line = end;
        }

        assert(spread <= range.to - range.from);

        return spread > 1;
    }

    fn operands(walk: *const Walk, node: u32) ?Operands {
        if (walk.tree.kind_at(node) != .binary_expr) return null;

        const left = walk.tree.child_first_of(node) orelse return null;
        const right = walk.tree.sibling_next_of(left) orelse return null;
        if (walk.tree.sibling_next_of(right) != null) return null;

        assert(left > node);
        assert(right > left);

        return .{ .left = left, .right = right };
    }

    fn listed(walk: *Walk, node: u32, filter: Filter) Range {
        assert(node < std.math.maxInt(u32));
        if (filter == .other_than) assert(filter.other_than < walk.tree.count());

        const from = walk.lists.count();
        var child = walk.tree.child_first_of(node);

        assert(node < walk.tree.count());

        for (0..walk.tree.count()) |_| {
            const held = child orelse break;

            if (walk.kept(held, filter)) {
                if (walk.lists.full()) break;

                walk.lists.push(held);
            }

            child = walk.tree.sibling_next_of(held);
        }

        assert(walk.lists.count() >= from);

        return .{ .from = from, .to = walk.lists.count() };
    }

    fn kept(walk: *const Walk, child: u32, filter: Filter) bool {
        assert(child < walk.tree.count());
        assert(walk.tree.parent_of(child) != null);
        if (filter == .all) return true;

        return switch (filter) {
            .all => true,
            .ends_by => |end| walk.end_of(child) <= end,
            .other_than => |node| child != node,
            .starts_after => |start| walk.start_of(child) > start,
        };
    }

    fn split_after(walk: *const Walk, range: Range, position: u32) u32 {
        assert(range.from <= range.to);
        assert(position < walk.kinds.len);

        for (range.from..range.to) |at| {
            const held = walk.item_at(@intCast(at));

            if (walk.start_of(held) > position) {
                assert(at < std.math.maxInt(u32));

                return @intCast(at);
            }
        }

        return range.to;
    }

    fn paren_after(walk: *const Walk, start: u32, end: u32) ?u32 {
        assert(start <= end);
        assert(end <= walk.kinds.len);

        const at = walk.code_from(start + 1, end) orelse return null;
        if (walk.kinds[at] != .paren_open) return null;
        assert(at < std.math.maxInt(u32));

        return at;
    }

    fn bracketed(walk: *const Walk, position: u32) bool {
        assert(position < walk.kinds.len);

        const kind = walk.kinds[position];

        assert(kind.is_token());

        return kind == .paren_open or kind == .bracket_open;
    }

    fn comment_within(walk: *const Walk, from: u32, to: u32) bool {
        assert(from <= to);
        assert(to <= walk.kinds.len);

        for (walk.kinds[from..to]) |kind| {
            if (kind == .comment) return true;
        }

        return false;
    }

    fn tag_literal(walk: *const Walk, node: u32) bool {
        assert(node < std.math.maxInt(u32));

        const held = walk.tree.at(node);
        if (held.kind != .basic_lit) return false;

        assert(held.token_start < walk.kinds.len);

        return walk.kinds[held.token_start] == .string_literal;
    }

    fn broken_at(walk: *const Walk, position: u32) bool {
        const last = walk.last orelse return false;

        assert(position < walk.lines.len);
        assert(last < walk.ends.len);

        return walk.lines[position] > walk.ends[last];
    }
};

const Stream = struct {
    aligned: bool,
    ends: []const u32,
    flags: []const u8,
    gaps: []const Gap,
    kinds: []const Kind,
    lines: []const u32,
    out: *Buffer,
    tail: Gap,
    text: []const u8,
    tokens: []const Token,

    fn gap_written(stream: *Stream, previous: ?u32, at: ?u32) error{Overflow}!void {
        if (previous) |held| assert(held < std.math.maxInt(u32));
        if (at) |held| assert(held < std.math.maxInt(u32));

        var buffer = if (at) |held| stream.gaps[held] else stream.tail;
        const end: u32 = at orelse @intCast(stream.kinds.len);
        const from: u32 = if (previous) |held| held + 1 else 0;
        var last = previous;
        var commented: ?u32 = null;

        assert(from <= end);
        assert(end <= stream.kinds.len);

        for (from..end) |position| {
            const held: u32 = @intCast(position);
            if (stream.kinds[held] != .comment) continue;

            try stream.prefix_written(&buffer, held, last, commented, at);
            try stream.comment_written(held);

            last = held;
            commented = held;
        }

        const comment = commented orelse return stream.bare_written(&buffer, previous, at);

        try stream.gap_commented(&buffer, previous, at, comment);
    }

    fn gap_commented(
        stream: *Stream,
        buffer: *Gap,
        previous: ?u32,
        at: ?u32,
        comment: u32,
    ) error{Overflow}!void {
        if (previous) |held| assert(held < std.math.maxInt(u32));
        if (at) |held| assert(held < std.math.maxInt(u32));
        assert(comment < stream.tokens.len);

        const token = stream.tokens[comment];
        const text = token.text(stream.text);
        const flags: u8 = if (at) |held| stream.flags[held] else 0;
        const kind: Kind = if (at) |held| stream.kinds[held] else .error_token;
        const line_next = if (at) |held| stream.lines[held] else std.math.maxInt(u32);
        const offset_next = stream.offset_of(at);
        const settled = try stream.gap_settled(buffer, previous, at, comment);
        const closer = kind == .brace_close and (flags & flag_no_break) == 0;
        const lined = text.len > 1 and text[1] == '/';
        const forced = lined or at == null or closer;
        var needs = settled.needs or forced;
        const dropped = items_dropped(buffer, &needs);
        var breaks = breaks_empty;

        assert(stream.kinds[comment] == .comment);
        if (previous) |held| assert(held < comment);

        try stream.whitespace_written(buffer, buffer.count, &breaks);

        const breaks_text = line_next -| stream.ends[comment];
        const constrained = constrains(stream.text, token.offset);
        const formfed = dropped and !constrained;
        const rest: u8 = if (formfed) 0x0c else '\n';

        if (breaks.count == 0) {
            if (needs) {
                breaks.kinds[0] = '\n';
                breaks.count = 1;
            }
        }

        if (constrained) breaks.kinds = @splat('\n');

        const indented = breaks.count > 0;

        const held = at orelse {
            const tail_count = @max(@min(breaks_text, 1), @min(breaks.count, 1));
            return stream.breaks_written(tail_count, breaks, rest, offset_next, indented);
        };

        const count = if (settled.moved) @max(breaks_text, 1) else breaks_text;

        try stream.breaks_written(count, breaks, rest, offset_next, indented);
        try stream.token_written(held);
    }

    fn gap_settled(
        stream: *Stream,
        buffer: *const Gap,
        previous: ?u32,
        at: ?u32,
        comment: u32,
    ) error{Overflow}!Settled {
        if (previous) |held| assert(held < std.math.maxInt(u32));
        if (at) |held| assert(held < std.math.maxInt(u32));
        assert(comment < stream.tokens.len);

        const text = stream.tokens[comment].text(stream.text);
        const flags: u8 = if (at) |held| stream.flags[held] else 0;
        const kind: Kind = if (at) |held| stream.kinds[held] else .error_token;
        const line_next = if (at) |held| stream.lines[held] else std.math.maxInt(u32);
        const opened = stream.opened_by(previous, kind);
        const blocked = text.len > 1 and text[1] == '*';
        const unparenthesized = kind != .paren_close or opened;
        const unbracketed = kind != .bracket_close or opened;
        const blank = (flags & flag_no_blank) == 0;
        const joined = stream.lines[comment] == line_next;
        const closed = kind != .comma and unparenthesized and unbracketed;
        const spaced = blank and blocked and joined and closed;

        assert(comment < stream.tokens.len);
        assert(stream.kinds[comment] == .comment);

        if (!spaced) return .{ .moved = false, .needs = false };

        const broken = items_broken(buffer);
        const free = (flags & flag_no_break) == 0 and (flags & flag_level) == 0;
        const moving = broken and free;
        if (moving) return .{ .moved = true, .needs = true };

        try stream.byte_written(' ');

        return .{ .moved = false, .needs = false };
    }

    fn offset_of(stream: *const Stream, at: ?u32) u32 {
        if (at) |held| assert(held < std.math.maxInt(u32));

        const held = at orelse {
            assert(stream.text.len <= std.math.maxInt(u32));

            return @intCast(stream.text.len);
        };
        const offset = stream.tokens[held].offset;

        assert(offset <= stream.text.len);

        return offset;
    }

    fn opened_by(stream: *const Stream, previous: ?u32, kind: Kind) bool {
        if (previous) |held| assert(held < std.math.maxInt(u32));

        const held = previous orelse return false;

        assert(held < stream.kinds.len);
        assert(kind.is_token());

        return switch (kind) {
            .paren_close => stream.kinds[held] == .paren_open,
            .bracket_close => stream.kinds[held] == .bracket_open,
            else => true,
        };
    }

    fn prefix_written(
        stream: *Stream,
        buffer: *Gap,
        held: u32,
        last: ?u32,
        comment: ?u32,
        at: ?u32,
    ) error{Overflow}!void {
        assert(held < stream.lines.len);
        if (last) |unwrapped| assert(unwrapped < std.math.maxInt(u32));
        if (comment) |unwrapped| assert(unwrapped < std.math.maxInt(u32));
        if (at) |unwrapped| assert(unwrapped < std.math.maxInt(u32));

        const line = stream.lines[held];
        const line_last = if (last) |value| stream.ends[value] else line;
        const line_next = if (at) |value| stream.lines[value] else std.math.maxInt(u32);
        const prior_text = if (comment) |prior| stream.tokens[prior].text(stream.text) else null;
        const block = if (prior_text) |held_text| blocked_of(held_text) else true;

        assert(stream.kinds[held] == .comment);
        if (last) |value| assert(value < held);

        if (last == null) {
            if (stream.out.empty()) return;
        }

        if (line == line_last) {
            if (block) return stream.prefix_joined(buffer, comment, line == line_next);
        }

        try stream.prefix_broken(buffer, held, last, at);
    }

    fn prefix_joined(
        stream: *Stream,
        buffer: *Gap,
        comment: ?u32,
        same: bool,
    ) error{Overflow}!void {
        if (comment) |held| assert(held < std.math.maxInt(u32));

        var breaks = breaks_empty;
        var separated = false;

        assert(buffer.count <= gap_items_max);

        if (comment == null) {
            var stop: u32 = 0;

            for (buffer.slice(), 0..) |item, index| {
                switch (item) {
                    .vtab => separated = true,
                    .indent => {},
                    else => {
                        stop = @intCast(index);

                        break;
                    },
                }
            }

            try stream.whitespace_written(buffer, stop, &breaks);
        }

        if (separated) assert(comment == null);

        if (separated) return;

        try stream.byte_written(if (same) ' ' else '\t');
    }

    fn prefix_broken(
        stream: *Stream,
        buffer: *Gap,
        held: u32,
        last: ?u32,
        at: ?u32,
    ) error{Overflow}!void {
        assert(held < stream.tokens.len);
        if (last) |unwrapped| assert(unwrapped < std.math.maxInt(u32));
        if (at) |unwrapped| assert(unwrapped < std.math.maxInt(u32));

        const comment = stream.tokens[held];
        const line = stream.lines[held];
        const line_last = if (last) |value| stream.ends[value] else line;
        var stop: u32 = 0;

        assert(stream.kinds[held] == .comment);
        if (last) |value| assert(value < held);

        for (0..buffer.count) |position| {
            const index: u32 = @intCast(position);

            switch (buffer.items[index]) {
                .vtab => {
                    buffer.items[index] = .ignore;

                    continue;
                },
                .indent => continue,
                .unindent => {
                    if (stream.unindent_kept(buffer, index, held, at)) continue;
                },
                .newline, .formfeed => buffer.items[index] = .ignore,
                .ignore => {},
            }

            stop = index;

            break;
        }

        var breaks = breaks_empty;

        assert(stop <= buffer.count);

        try stream.whitespace_written(buffer, stop, &breaks);

        const count = line -| line_last;
        const constrained = if (last) |value| stream.constrained_at(value) else false;
        const kind: u8 = if (constrained) '\n' else 0x0c;

        try stream.breaks_written(count, breaks_empty, kind, comment.offset, false);
    }

    fn unindent_kept(
        stream: *const Stream,
        buffer: *const Gap,
        index: u32,
        held: u32,
        at: ?u32,
    ) bool {
        assert(buffer.items[index] == .unindent);
        assert(held < stream.tokens.len);
        if (at) |unwrapped| assert(unwrapped < std.math.maxInt(u32));

        const doubled = index + 1 < buffer.count and buffer.items[index + 1] == .unindent;
        const closer = if (at) |value| stream.kinds[value] == .brace_close else false;
        const offset = stream.tokens[held].offset;

        const aligned = if (at) |value|
            column_of(stream.text, offset) == column_of(stream.text, stream.tokens[value].offset)
        else
            false;

        assert(index < buffer.count);

        return doubled or (!closer and aligned);
    }

    fn constrained_at(stream: *const Stream, last: u32) bool {
        assert(last < stream.kinds.len);
        assert(stream.tokens.len == stream.kinds.len);

        if (stream.kinds[last] != .comment) return false;
        return constrains(stream.text, stream.tokens[last].offset);
    }

    fn bare_written(stream: *Stream, buffer: *Gap, previous: ?u32, at: ?u32) error{Overflow}!void {
        if (previous) |held| assert(held < std.math.maxInt(u32));
        if (at) |held| assert(held < std.math.maxInt(u32));

        const line_next = if (at) |held| stream.lines[held] else std.math.maxInt(u32);
        const offset_next = stream.offset_of(at);
        const breaks_text: u32 = if (previous) |held| line_next -| stream.ends[held] else 0;

        assert(offset_next <= stream.text.len);

        const held = at orelse {
            const tail_count = @min(breaks_text, 1);
            return stream.breaks_written(tail_count, breaks_empty, '\n', offset_next, true);
        };

        var breaks = breaks_empty;
        const length = buffer.count;

        if (breaks_text > 0) {
            try stream.whitespace_written(buffer, length, &breaks);
            try stream.breaks_written(breaks_text, breaks, '\n', offset_next, true);

            return stream.token_written(held);
        }

        if (std.mem.findScalar(Item, buffer.slice(), .vtab) != null) {
            try stream.whitespace_written(buffer, length, &breaks);

            return stream.token_written(held);
        }

        const gap_start: u32 = if (previous) |value| stream.tokens[value].end() else 0;

        assert(gap_start <= offset_next);

        for (stream.text[gap_start..offset_next]) |byte| {
            try stream.byte_written(byte);
        }

        try stream.token_written(held);
    }

    fn whitespace_written(
        stream: *Stream,
        buffer: *Gap,
        count: u32,
        breaks: *Breaks,
    ) error{Overflow}!void {
        assert(count < std.math.maxInt(u32));

        const written: u8 = @intCast(@min(count, buffer.count));

        assert(buffer.count <= gap_items_max);

        for (0..written) |position| {
            const item = buffer.items[position];

            switch (item) {
                .vtab => {
                    if (breaks.count == 0) try stream.byte_written(0x0b);
                },
                .newline, .formfeed => {
                    const following = position + 1 < written;
                    const unindented = following and buffer.items[position + 1] == .unindent;
                    const formfed = unindented or item == .formfeed;
                    const kind: u8 = if (formfed) 0x0c else '\n';

                    if (breaks.count < break_kinds_max) breaks.kinds[breaks.count] = kind;

                    breaks.count += 1;
                },
                .ignore, .indent, .unindent => {},
            }
        }

        const kept_count = buffer.count - written;
        const kept_items = buffer.items[written..buffer.count];

        @memmove(buffer.items[0..kept_count], kept_items);
        buffer.count = kept_count;

        assert(buffer.count <= gap_items_max);
    }

    fn breaks_written(
        stream: *Stream,
        count: u32,
        known: Breaks,
        rest: u8,
        offset: u32,
        indented: bool,
    ) error{Overflow}!void {
        assert(count < std.math.maxInt(u32));
        assert(offset < std.math.maxInt(u32));
        assert(rest == '\n' or rest == 0x0c);
        if (known.count > 0) assert(known.kinds[0] == '\n' or known.kinds[0] == 0x0c);

        const indent = indent_at(stream.text, offset);

        assert(offset <= stream.text.len);

        for (0..count) |position| {
            const at: u32 = @intCast(position);

            if (at > 0) {
                if (indented) try stream.tabs_written(indent);
            }

            try stream.byte_written(known.kind_at(at, rest));
        }

        if (count == 0) return;

        try stream.tabs_written(indent);

        assert(stream.out.count() >= count);
    }

    fn tabs_written(stream: *Stream, count: u32) error{Overflow}!void {
        assert(count <= stream.text.len);

        for (0..count) |_| {
            try stream.out.push("\t");
        }

        assert(stream.out.count() >= count);
    }

    fn byte_written(stream: *Stream, byte: u8) error{Overflow}!void {
        const count = stream.out.count();
        var written = byte;

        if (stream.aligned) {
            switch (byte) {
                '\t', 0x0b => written = ' ',
                '\n', 0x0c => {
                    stream.aligned = false;
                    written = 0x0c;
                },
                else => {},
            }
        }

        if (written != byte) assert(byte != ' ');

        try stream.out.push_byte(written);

        assert(stream.out.count() == count + 1);
    }

    fn escaped_written(stream: *Stream, bytes: []const u8) error{Overflow}!void {
        const count = stream.out.count();

        assert(bytes.len <= stream.text.len);

        try stream.out.push_byte(escape);
        try stream.out.push(bytes);
        try stream.out.push_byte(escape);

        assert(stream.out.count() == count + bytes.len + 2);
    }

    fn token_written(stream: *Stream, at: u32) error{Overflow}!void {
        assert(at < stream.tokens.len);

        const token = stream.tokens[at];
        const text = token.text(stream.text);

        assert(coded(stream.kinds[at]));
        assert(token.end() <= stream.text.len);

        if (!literal(stream.kinds[at])) return stream.out.push(text);

        if (std.mem.findScalar(u8, text, '\n') != null) stream.aligned = true;

        try stream.escaped_written(text);
    }

    fn comment_written(stream: *Stream, at: u32) error{Overflow}!void {
        assert(at < stream.tokens.len);

        const comment = stream.tokens[at];
        const text = comment.text(stream.text);

        assert(stream.kinds[at] == .comment);

        if (std.mem.findScalar(u8, text, '\n') == null) return stream.escaped_written(text);

        const base = indent_at(stream.text, comment.offset);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var empty = false;

        try stream.escaped_written(lines.first());

        for (0..text.len) |_| {
            const line = lines.next() orelse break;

            if (empty) try stream.tabs_written(base);

            try stream.byte_written(0x0c);

            const tab_count = @min(tabs_leading(line), base);

            empty = line.len == 0;

            if (empty) continue;

            try stream.tabs_written(tab_count);
            try stream.escaped_written(line[tab_count..]);
        }
    }
};

const Task = union(enum) {
    assign: Assign,
    binary: Binary,
    block: Block,
    call: Call,
    children: Children,
    clause: Clause,
    composite: Composite,
    expr_list: ExprList,
    field: Field,
    field_list: FieldList,
    file: File,
    func_body: FuncBody,
    gen_decl: GenDecl,
    if_stmt: IfStmt,
    index_list: IndexList,
    labeled: Labeled,
    listed: Listed,
    parameters: Parameters,
    return_stmt: ReturnStmt,
    selector: Selector,
    spec_type: SpecType,
    statements: Statements,
    struct_field: StructField,
    value_spec: ValueSpec,
};

const Assign = struct {
    stage: enum { start, left, right } = .start,
    depth: u32,
    from: u32 = 0,
    node: u32,
    operator: u32 = 0,
    split: u32 = 0,
    to: u32 = 0,
};

const Binary = struct {
    stage: enum { start, operands, right } = .start,
    at: u32 = 0,
    depth: u32,
    expression: u32 = 0,
    from: u32 = 0,
    node: u32,
    unindent: bool = false,
};

const Block = struct {
    stage: enum { start, closed } = .start,
    depth: u32,
    from: u32 = 0,
    indent: u32,
    node: u32,
};

const Call = struct {
    stage: enum { start, callee, dotted, closed } = .start,
    callee: u32 = 0,
    depth: u32,
    dots: u32 = 0,
    from: u32 = 0,
    indented: bool = false,
    node: u32,
    open: u32 = 0,
    selecting: bool = false,
};

const Children = struct {
    child: ?u32,
    depth: u32,
    mode: Mode,
    node: u32,
};

const Clause = struct {
    stage: enum { start, comm, listed, closed } = .start,
    at: u32 = 0,
    closing: bool,
    colon: u32 = 0,
    depth: u32,
    from: u32 = 0,
    node: u32,
    split: u32 = 0,
    to: u32 = 0,
};

const Composite = struct {
    stage: enum { start, head, listed } = .start,
    depth: u32,
    from: u32 = 0,
    node: u32,
    open: u32 = 0,
    to: u32 = 0,
};

const ExprList = struct {
    stage: enum { start, inlined, elements, keyed, valued, finished } = .start,
    after: ?u32,
    at: u32 = 0,
    before: ?u32,
    break_previous: i64 = -1,
    count: u32 = 0,
    depth: u32,
    element: u32 = 0,
    from: u32,
    key: u32 = 0,
    line: u32 = 0,
    line_previous: u32 = 0,
    mode: u8,
    size: u32 = 0,
    sum: f64 = 0.0,
    to: u32,
    ws: ?Item = null,
};

const Field = struct {
    stage: enum { start, named, typed } = .start,
    child_last: ?u32 = null,
    depth: u32,
    indent: bool,
    node: u32,
};

const FieldList = struct {
    stage: enum { start, fields } = .start,
    at: u32 = 0,
    depth: u32,
    from: u32 = 0,
    line: u32 = 0,
    node: u32,
    separator: ?Item = null,
    structured: bool = false,
    to: u32 = 0,
};

const File = struct {
    child: ?u32,
    depth: u32,
    node: u32,
    previous: ?Kind = null,
};

const FuncBody = struct {
    stage: enum { start, statements, closed } = .start,
    child: ?u32 = null,
    depth: u32,
    level: u32 = 0,
    node: u32,
    separator: ?Item,
};

const GenDecl = struct {
    stage: enum { start, specs, closed } = .start,
    at: u32 = 0,
    base: u32 = 0,
    depth: u32,
    from: u32 = 0,
    line: u32 = 0,
    node: u32,
    to: u32 = 0,
    valued: bool = false,
};

const IfStmt = struct {
    bodied: bool = false,
    child: ?u32,
    depth: u32,
    node: u32,
    tail: u32,
};

const IndexList = struct {
    stage: enum { start, operand, listed } = .start,
    depth: u32,
    from: u32 = 0,
    node: u32,
    operand: u32 = 0,
};

const Labeled = struct {
    stage: enum { start, children } = .start,
    child: ?u32 = null,
    closing: bool,
    colon: u32 = 0,
    depth: u32,
    node: u32,
};

const Listed = struct {
    stage: enum { start, closed } = .start,
    depth: u32,
    end: ?u32,
    filter: Filter,
    from: u32 = 0,
    mode: u8,
    node: u32,
};

const Parameters = struct {
    stage: enum { start, fields, closed } = .start,
    depth: u32,
    line_previous: u32 = 0,
    node: u32,
    parameter: ?u32 = null,
    ws: ?Item = null,
};

const ReturnStmt = struct {
    stage: enum { start, listed } = .start,
    depth: u32,
    from: u32 = 0,
    indented: bool = false,
    node: u32,
};

const Selector = struct {
    stage: enum { start, operand, named, fallback } = .start,
    broken: bool = false,
    depth: u32,
    method: bool,
    name: u32 = 0,
    node: u32,
};

const SpecType = struct {
    stage: enum { start, named, typed, children } = .start,
    child: ?u32 = null,
    count: u32,
    depth: u32,
    node: u32,
};

const Statements = struct {
    stage: enum { start, items } = .start,
    at: u32,
    closing: bool,
    depth: u32,
    from: u32,
    indent: u32,
    index: u32 = 0,
    line: u32 = 0,
    to: u32,
};

const StructField = struct {
    stage: enum { start, named, typed } = .start,
    count: u32 = 0,
    depth: u32,
    from: u32 = 0,
    named: bool = false,
    node: u32,
    separator: ?Item,
    tag: ?u32 = null,
};

const ValueSpec = struct {
    stage: enum { start, named, typed, valued } = .start,
    aligned: bool,
    depth: u32,
    equal: ?u32 = null,
    extra: u32 = 3,
    keep: bool,
    node: u32,
    typed: ?u32 = null,
};

const Mode = enum {
    func_decl,
    func_lit,
    func_type,
    generic,
    headed,
    interface_field,
    switch_stmt,
};

const Filter = union(enum) {
    all,
    ends_by: u32,
    other_than: u32,
    starts_after: u32,
};

const Range = struct {
    from: u32,
    to: u32,
};

const Parts = struct {
    equal: ?u32,
    names_end: u32,
    typed: ?u32,
};

const Operands = struct {
    left: u32,
    right: u32,
};

const Settled = struct {
    moved: bool,
    needs: bool,
};

const Resumed = enum {
    yielded,
    returned,
};

const break_kinds_max: u32 = 4;
const comma_term: u8 = 1;
const depth_max: u32 = 512;
const flag_level: u8 = 1;
const flag_no_blank: u8 = 2;
const flag_no_break: u8 = 4;
const gap_items_max: u8 = 16;
const no_indent: u8 = 2;
const resume_count_max: u64 = std.math.maxInt(u32);
const size_ratio: f64 = 2.5;
const small_size: u32 = 40;
const task_chain_max: u32 = 8;
const task_count_max: u32 = (depth_max + 1) * task_chain_max;
const gap_empty: Gap = .{ .count = 0, .items = @splat(.ignore) };
const breaks_empty: Breaks = .{ .count = 0, .kinds = @splat('\n') };

comptime {
    assert(task_count_max > depth_max);
    assert(gap_items_max > 0);
    assert(break_kinds_max > 0);
    assert(flag_level & flag_no_blank == 0);
    assert(flag_no_blank & flag_no_break == 0);
    assert(comma_term & no_indent == 0);
}

fn block_of(node: u32, indent: u32, depth: u32) Task {
    assert(indent <= 1);
    assert(depth <= std.math.maxInt(u32) - 1);
    assert(node < std.math.maxInt(u32));

    return .{ .block = .{ .depth = depth, .indent = indent, .node = node } };
}

fn expr_list_of(before: ?u32, range: Range, mode: u8, after: ?u32, depth: u32) Task {
    assert(range.from <= range.to);
    assert(mode <= comma_term | no_indent);
    if (before) |held| assert(held < std.math.maxInt(u32));
    if (after) |held| assert(held < std.math.maxInt(u32));
    assert(depth <= depth_max);

    return .{ .expr_list = .{
        .after = after,
        .before = before,
        .depth = depth,
        .from = range.from,
        .mode = mode,
        .to = range.to,
    } };
}

fn names_of(spec: u32, names_end: u32, indent: bool, depth: u32) Task {
    assert(depth <= std.math.maxInt(u32) - 1);
    assert(names_end != std.math.maxInt(u32));
    assert(spec < std.math.maxInt(u32));

    return .{ .listed = .{
        .depth = depth,
        .end = names_end,
        .filter = .{ .ends_by = names_end },
        .mode = if (indent) 0 else no_indent,
        .node = spec,
    } };
}

fn values_of(spec: u32, equal: u32, depth: u32) Task {
    assert(depth <= std.math.maxInt(u32) - 1);
    assert(equal != std.math.maxInt(u32));
    assert(spec < std.math.maxInt(u32));

    return .{ .listed = .{
        .depth = depth,
        .end = null,
        .filter = .{ .starts_after = equal },
        .mode = 0,
        .node = spec,
    } };
}

fn statements_of(range: Range, indent: u32, closing: bool, depth: u32) Task {
    assert(range.from <= range.to);
    assert(indent <= 1);
    assert(depth <= depth_max);

    return .{ .statements = .{
        .at = range.from,
        .closing = closing,
        .depth = depth,
        .from = range.from,
        .indent = indent,
        .to = range.to,
    } };
}

fn expr_list_formfeed(state: *const ExprList, size_previous: u32) bool {
    assert(state.from < state.to);

    if (size_previous == 0) return true;
    if (state.size == 0) return true;
    if (state.count == 0) return false;

    const small = size_previous <= small_size and state.size <= small_size;
    if (small) return false;

    const mean = go_exp(state.sum / @as(f64, @floatFromInt(state.count)));
    const ratio = @as(f64, @floatFromInt(state.size)) / mean;

    assert(state.count > 0);

    return size_ratio * ratio <= 1.0 or size_ratio <= ratio;
}

fn items_dropped(buffer: *Gap, needs: *bool) bool {
    var dropped = false;

    assert(buffer.count <= gap_items_max);

    for (buffer.items[0..buffer.count]) |*item| {
        switch (item.*) {
            .vtab => item.* = .ignore,
            .newline, .formfeed => {
                if (needs.*) {
                    needs.* = false;
                } else {
                    dropped = dropped or item.* == .formfeed;
                    item.* = .ignore;
                }
            },
            .ignore, .indent, .unindent => {},
        }
    }

    assert(std.mem.findScalar(Item, buffer.slice(), .vtab) == null);

    return dropped;
}

fn items_broken(buffer: *const Gap) bool {
    assert(buffer.count <= gap_items_max);

    for (buffer.slice()) |item| {
        if (item == .newline) return true;
        if (item == .formfeed) return true;
    }

    return false;
}

fn blocked_of(text: []const u8) bool {
    assert(text.len > 0);
    assert(text[0] == '/');

    return text.len > 1 and text[1] == '*';
}

fn go_exp(x: f64) f64 {
    const ln2_upper: f64 = 0.693_147_180_559_662_956_511_601_805_686_950_683_593_75;
    const ln2_lower: f64 = 0.282_352_905_630_315_771_225_884_481_750_134_360_255_254_120_68e-12;
    const overflow: f64 = 7.097_827_128_933_84e2;

    const taylor = [7]f64{
        1.984_126_984_126_984_127_0e-4,
        1.388_888_888_888_888_888_9e-3,
        8.333_333_333_333_333_333_3e-3,
        4.166_666_666_666_666_666_7e-2,
        1.666_666_666_666_666_666_7e-1,
        0.5,
        1.0,
    };

    if (std.math.isNan(x)) return x;
    if (x == std.math.inf(f64)) return x;
    if (x == -std.math.inf(f64)) return 0.0;
    if (x > overflow) return std.math.inf(f64);

    const exponent = exponent_of(x * std.math.log2e);
    const scale: f64 = @floatFromInt(exponent);
    var reduced = @mulAdd(f64, -scale, ln2_upper, x);

    assert(exponent <= 1024);

    reduced = @mulAdd(f64, -scale, ln2_lower, reduced);
    reduced *= 0.0625;

    var series: f64 = 2.480_158_730_158_730_158_7e-5;

    for (taylor) |coefficient| {
        series = @mulAdd(f64, series, reduced, coefficient);
    }

    reduced *= series;

    for (0..3) |_| {
        const doubled = reduced + 2.0;

        reduced *= doubled;
    }

    const doubled_final = reduced + 2.0;

    reduced = @mulAdd(f64, reduced, doubled_final, 1.0);

    const biased = exponent + 0x3ff;
    if (biased <= 0) return 0.0;
    if (biased >= 0x7ff) return std.math.inf(f64);

    const bits: u64 = @as(u64, @intCast(biased)) << 52;
    const result = reduced * @as(f64, @bitCast(bits));

    assert(result >= 0.0);

    return result;
}

fn exponent_of(value: f64) i32 {
    assert(!std.math.isNan(value));

    const rounded = round_ties_even(value);

    assert(@trunc(rounded) == rounded);

    if (rounded <= -2147483648.0) return std.math.minInt(i32);
    if (rounded >= 2147483647.0) return std.math.maxInt(i32);
    return @trunc(rounded);
}

fn round_ties_even(value: f64) f64 {
    assert(!std.math.isNan(value));

    const truncated = @trunc(value);
    const fraction = value - truncated;
    const tie = @abs(fraction) == 0.5;
    const even = @mod(truncated, 2.0) == 0.0;
    const kept = tie and even;
    const result = if (kept) truncated else @round(value);

    if (std.math.isFinite(value)) assert(@abs(result - value) <= 0.5);

    return result;
}

fn go_log(x: f64) f64 {
    const half_sqrt2: f64 = std.math.sqrt1_2;
    const ln2_high: f64 = 6.931_471_803_691_238_164_90e-1;
    const ln2_low: f64 = 1.908_214_929_270_587_700_02e-10;
    const l1: f64 = 6.666_666_666_666_735_130e-1;
    const l2: f64 = 3.999_999_999_940_941_908e-1;
    const l3: f64 = 2.857_142_874_366_239_149e-1;
    const l4: f64 = 2.222_219_843_214_978_396e-1;
    const l5: f64 = 1.818_357_216_161_805_012e-1;
    const l6: f64 = 1.531_383_769_920_937_332e-1;
    const l7: f64 = 1.479_819_860_511_658_591e-1;

    if (x == 0.0) return -std.math.inf(f64);
    if (x < 0.0) return std.math.nan(f64);
    if (std.math.isNan(x)) return std.math.nan(f64);
    if (x == std.math.inf(f64)) return x;

    const bits: u64 = @bitCast(x);
    var fraction: f64 = @bitCast((bits & 0x000f_ffff_ffff_ffff) | 0x3fe0_0000_0000_0000);
    const field: i32 = @intCast((bits >> 52) & 0x7ff);
    var power: f64 = @floatFromInt(field - 0x3fe);
    const halved: f64 = if (fraction <= half_sqrt2) 1.0 else 0.0;

    assert(fraction >= 0.5);
    assert(fraction < 1.0);

    power -= halved;
    fraction *= halved + 1.0;

    const shifted = fraction - 1.0;
    const ratio = shifted / (2.0 + shifted);
    const s2 = ratio * ratio;
    const s4 = s2 * s2;
    const t1 = s2 * ((((l7 * s4 + l5) * s4 + l3) * s4) + l1);
    const t2 = s4 * (((l6 * s4 + l4) * s4) + l2);
    const sum = t1 + t2;
    const half_square = 0.5 * shifted * shifted;
    const tail = ratio * (half_square + sum) + ln2_low * power;
    const logarithm = power * ln2_high - ((half_square - tail) - shifted);

    assert(!std.math.isNan(logarithm));

    return logarithm;
}

fn coded(kind: Kind) bool {
    assert(kind.is_token());

    return kind != .comment and kind != .newline;
}

fn literal(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .number, .rune_literal, .string_literal => true,
        else => false,
    };
}

fn newlines(bytes: []const u8) u32 {
    assert(bytes.len <= std.math.maxInt(u32));

    var count: u32 = 0;

    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }

    assert(count <= bytes.len);

    return count;
}

fn indent_at(text: []const u8, offset: u32) u32 {
    assert(offset <= text.len);

    const start = line_start_of(text, offset);
    var count: u32 = 0;

    for (text[start..]) |byte| {
        if (byte != '\t') break;

        count += 1;
    }

    assert(start + count <= text.len);

    return count;
}

fn tabs_leading(line: []const u8) u32 {
    assert(line.len <= std.math.maxInt(u32));

    var count: u32 = 0;

    for (line) |byte| {
        if (byte != '\t') break;

        count += 1;
    }

    assert(count <= line.len);

    return count;
}

fn constrains(text: []const u8, offset: u32) bool {
    assert(offset <= text.len);

    const rest = text[@min(offset, text.len)..];

    assert(rest.len <= text.len);

    if (std.mem.startsWith(u8, rest, "//go:build")) return true;
    return std.mem.startsWith(u8, rest, "// +build");
}

fn column_of(text: []const u8, offset: u32) u32 {
    assert(offset <= text.len);

    const column = offset - line_start_of(text, offset) + 1;

    assert(column > 0);

    return column;
}

fn line_start_of(text: []const u8, offset: u32) u32 {
    assert(offset <= text.len);

    const found = std.mem.findScalarLast(u8, text[0..offset], '\n') orelse return 0;

    assert(found < offset);

    return @intCast(found + 1);
}

test "the cells stream is the Rust raw stream byte for byte" {
    const gpa = std.testing.allocator;
    var cells: Cells = try .init(gpa, 1 << 10);
    defer cells.deinit(gpa);

    var out: Buffer = try .init(gpa, 1 << 14);
    defer out.deinit(gpa);

    for (expected_streams) |case| {
        try expect_stream(&cells, &out, case);
    }
}

test "the cells stream refuses a token table it outgrows" {
    const gpa = std.testing.allocator;
    var cells: Cells = try .init(gpa, 4);
    defer cells.deinit(gpa);

    var out: Buffer = try .init(gpa, 1 << 8);
    defer out.deinit(gpa);

    const outgrown = cells.written("package main\n\nvar x = 1\n", &out);

    try std.testing.expectError(error.Overflow, outgrown);
    try cells.written("package main\n", &out);
    try std.testing.expectEqualStrings("package main\n", out.const_slice());
}

test "the cells stream refuses an output buffer it outgrows" {
    const gpa = std.testing.allocator;
    var cells: Cells = try .init(gpa, 1 << 8);
    defer cells.deinit(gpa);

    var out: Buffer = try .init(gpa, 8);
    defer out.deinit(gpa);

    const outgrown = cells.written("package main\n", &out);

    try std.testing.expectError(error.Overflow, outgrown);
}

test "go_exp is the Rust go_exp bit for bit" {
    for (expected_exponentials) |case| {
        const input: f64 = @bitCast(case.input);
        const output: u64 = @bitCast(go_exp(input));

        try std.testing.expectEqual(case.output, output);
    }

    try std.testing.expect(std.math.isNan(go_exp(std.math.nan(f64))));
}

test "go_log is the Rust go_log bit for bit" {
    for (expected_logarithms) |case| {
        const input: f64 = @bitCast(case.input);
        const output: u64 = @bitCast(go_log(input));

        try std.testing.expectEqual(case.output, output);
    }

    try std.testing.expect(std.math.isNan(go_log(std.math.nan(f64))));
}

test "the float constants are the Rust constants" {
    const log2e: f64 = std.math.log2e;
    const sqrt1_2: f64 = std.math.sqrt1_2;

    try std.testing.expectEqual(@as(u64, 0x3ff71547652b82fe), @as(u64, @bitCast(log2e)));
    try std.testing.expectEqual(@as(u64, 0x3fe6a09e667f3bcd), @as(u64, @bitCast(sqrt1_2)));
}

test "a tie rounds to the even neighbour" {
    try std.testing.expectEqual(@as(f64, 2.0), round_ties_even(2.5));
    try std.testing.expectEqual(@as(f64, 4.0), round_ties_even(3.5));
    try std.testing.expectEqual(@as(f64, -2.0), round_ties_even(-2.5));
    try std.testing.expectEqual(@as(f64, -4.0), round_ties_even(-3.5));
    try std.testing.expectEqual(@as(f64, 0.0), round_ties_even(0.5));
    try std.testing.expectEqual(@as(f64, 3.0), round_ties_even(2.6));
    try std.testing.expectEqual(@as(f64, -3.0), round_ties_even(-2.6));
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), exponent_of(-1.0e300));
}

const Stream_case = struct {
    text: []const u8,
    written: ?[]const u8,
};

const Bits = struct {
    input: u64,
    output: u64,
};

fn expect_stream(cells: *Cells, out: *Buffer, case: Stream_case) !void {
    assert(case.text.len > 0);

    const result = cells.written(case.text, out);
    const expected = case.written orelse return std.testing.expectError(error.Overflow, result);

    try result;
    try std.testing.expectEqualStrings(expected, out.const_slice());
}

const expected_streams = [_]Stream_case{
    .{
        .text = "package main\n",
        .written = "package main\n",
    },
    .{
        .text = "package main\n\nconst (\n\ta = 1\n\tbbb = 2 // comment\n)\n",
        .written = "package main\n\nconst (\x0c\ta\x0b= \xff1\xff\n" ++
            "\tbbb\x0b= \xff2\xff\x0b\x0b\xff// comment\xff\x0c)\n",
    },
    .{
        .text = "package main\n\ntype T struct {\n\tName string `json:\"name\"`\n\tX int\n}\n",
        .written = "package main\n\ntype T struct {\x0c\tName\x0bstring\x0b\x0b" ++
            "\xff`json:\"name\"`\xff\n\tX\x0bint\x0c}\n",
    },
    .{
        .text = "package main\n\nfunc f() { return }\n\n// doc\n" ++
            "func g(a int, b string) (int, error) {\n\treturn a, nil\n}\n",
        .written = "package main\n\nfunc f()\x0b{ return }\x0c\x0c\xff// doc\xff\n" ++
            "func g(a int, b string) (int, error) {\x0c\treturn a, nil\x0c}\n",
    },
    .{
        .text = "package main\n\nvar m = map[string]int{\n\t\"a\": 1,\n\t\"bbbb\": 2,\n}\n",
        .written = "package main\n\nvar m = map[string]int{\x0c\t\xff\"a\"\xff:\x0b\xff1\xff,\n" ++
            "\t\xff\"bbbb\"\xff:\x0b\xff2\xff,\x0c}\n",
    },
    .{
        .text = "package main\n\nfunc f(x int) {\nL:\n\tswitch x {\n\tcase 1:\n" ++
            "\t\tbreak L\n\tdefault:\n\t}\n}\n",
        .written = "package main\x0c\nfunc f(x int) {\x0cL:\x0c\tswitch x {\x0c" ++
            "\tcase \xff1\xff:\x0c\t\tbreak L\x0c\tdefault:\x0c\t}\x0c}\n",
    },
    .{
        .text = "package main\n\nfunc f(xs ...int) {\n\tg(1,\n\t\txs...)\n}\n",
        .written = "package main\x0c\nfunc f(xs ...int) {\x0c\tg(\xff1\xff,\x0c" ++
            "\t\txs...)\x0c}\n",
    },
    .{
        .text = "package main\n\nvar x = /* a */ 1 /* b */\n\nfunc f(a /* c */ int) {}\n",
        .written = "package main\n\nvar x = \xff/* a */\xff \xff1\xff\t\xff/* b */\xff\n\n" ++
            "func f(a \xff/* c */\xff int)\x0b{}\n",
    },
    .{
        .text = "package main\n\nvar (\n\ta int = 1\n\tbb = 2\n\tc string\n)\n",
        .written = "package main\n\nvar (\x0c\ta\x0bint\x0b= \xff1\xff\n" ++
            "\tbb\x0b\x0b= \xff2\xff\n\tc\x0bstring\x0c)\n",
    },
    .{
        .text = "package main\n\ntype I interface {\n\tM(a int) error\n\tN()\n}\n",
        .written = "package main\n\ntype I interface {\x0c\tM(a int) error\n\tN()\x0c}\n",
    },
    .{
        .text = "package main\n\nfunc f(x int) {\n\tif x > 1 {\n\t\tx++\n" ++
            "\t} else if x < 0 {\n\t\tx--\n\t} else {\n\t\tx = 0\n\t}\n}\n",
        .written = "package main\x0c\nfunc f(x int) {\x0c\tif x > \xff1\xff {\x0c\t\tx++\x0c" ++
            "\t} else if x < \xff0\xff {\x0c\t\tx--\x0c\t} else {\x0c" ++
            "\t\tx = \xff0\xff\x0c\t}\x0c}\n",
    },
    .{
        .text = "package main\n\nvar y = 1 +\n\t2 +\n\t3\n",
        .written = "package main\n\nvar y = \xff1\xff +\x0c\t\xff2\xff +\x0c\t\xff3\xff\n",
    },
    .{
        .text = "package main\n\nvar z = a.\n\tb.\n\tc()\n",
        .written = "package main\n\nvar z = a.\n\tb.\n\tc()\n",
    },
    .{
        .text = "//go:build linux\n\npackage main\n",
        .written = "\xff//go:build linux\xff\n\npackage main\n",
    },
    .{
        .text = "package main\n\nvar s = `a\n\tb`\nvar t = 1\n",
        .written = "package main\n\nvar s = \xff`a\n\tb`\xff\x0cvar t = \xff1\xff\n",
    },
    .{
        .text = "package main\n\nfunc f() {\n\tx := []int{1, 2,\n\t\t3}\n\t_ = x\n}\n",
        .written = "package main\x0c\nfunc f() {\x0c\tx := []int{\xff1\xff, \xff2\xff,\x0c" ++
            "\t\t\xff3\xff}\x0c\t_ = x\x0c}\n",
    },
    .{
        .text = "package main\n\nvar m = map[string]int{\n\t\"a\":" ++ @as([23]u8, @splat(' ')) ++
            "1,\n" ++ "\t\"" ++ @as([52]u8, @splat('b')) ++ "\": 2,\n\t\"c\": 3,\n}\n",
        .written = "package main\n\nvar m = map[string]int{\x0c" ++
            "\t\xff\"a\"\xff:\x0b\xff1\xff,\x0c" ++
            "\t\xff\"" ++ @as([52]u8, @splat('b')) ++ "\"\xff:\x0b\xff2\xff,\x0c" ++
            "\t\xff\"c\"\xff:\x0b\xff3\xff,\x0c}\n",
    },
    .{
        .text = "package main\n\ntype (\n\tA int\n\tB[T any] struct{}\n)\n",
        .written = "package main\n\ntype (\x0c\tA\x0bint\n\tB[T any]\x0bstruct{}\x0c)\n",
    },
    .{
        .text = "package main\n\nfunc f() {\n\tselect {}\n\tfor i := 0; i < 3; i++ {\n\t}\n}\n",
        .written = "package main\x0c\nfunc f() {\x0c\tselect {}\n" ++
            "\tfor i := \xff0\xff; i < \xff3\xff; i++ {\x0c\t}\x0c}\n",
    },
    .{
        .text = "package main\n\nfunc f() (\n\ta int,\n\tb int,\n) {\n\treturn 1,\n\t\t2\n}\n",
        .written = "package main\x0c\nfunc f() (\x0c\ta int,\x0c\tb int,\x0c) {\x0c" ++
            "\treturn \xff1\xff,\x0c\t\t\xff2\xff\x0c}\n",
    },
    .{
        .text = "package main\n\nfunc f() {\n\t// lead\n\tx := 1 // trail\n" ++
            "\t/* block */ _ = x\n}\n",
        .written = "package main\x0c\nfunc f() {\x0c\t\xff// lead\xff\n" ++
            "\tx := \xff1\xff\t\xff// trail\xff\x0c\t\xff/* block */\xff _ = x\x0c}\n",
    },
    .{
        .text = "package main\n\nfunc (",
        .written = null,
    },
};

const expected_exponentials = [_]Bits{
    .{ .input = 0x0000000000000000, .output = 0x3ff0000000000000 },
    .{ .input = 0x3ff0000000000000, .output = 0x4005bf0a8b145769 },
    .{ .input = 0xbff0000000000000, .output = 0x3fd78b56362cef38 },
    .{ .input = 0x3fe0000000000000, .output = 0x3ffa61298e1e069c },
    .{ .input = 0x4004000000000000, .output = 0x40285d6fd931e0bb },
    .{ .input = 0x400c000000000000, .output = 0x40408ec721396bdb },
    .{ .input = 0x40083a66f6af1e66, .output = 0x4034aaa35b973293 },
    .{ .input = 0x400d82d33b32720d, .output = 0x4044000000000000 },
    .{ .input = 0x40111b4e5cf4573f, .output = 0x4052000000000000 },
    .{ .input = 0x401ba18a998fffa0, .output = 0x408f3ffffffffffe },
    .{ .input = 0x4024000000000000, .output = 0x40d5829dcf950560 },
    .{ .input = 0x4059000000000000, .output = 0x48f3494a9b171bf5 },
    .{ .input = 0x4085e00000000000, .output = 0x7f0d945df4f8ec8e },
    .{ .input = 0x4086280000000000, .output = 0x7fdd422d2be5dc9b },
    .{ .input = 0x40862e3d70a3d70a, .output = 0x7ff0000000000000 },
    .{ .input = 0x4086300000000000, .output = 0x7ff0000000000000 },
    .{ .input = 0xc085e00000000000, .output = 0x00d14f2b0fb9307f },
    .{ .input = 0xc087480000000000, .output = 0x0000000000000000 },
    .{ .input = 0xc087500000000000, .output = 0x0000000000000000 },
    .{ .input = 0xfe37e43c8800759c, .output = 0x0000000000000000 },
    .{ .input = 0x01a56e1fc2f8f359, .output = 0x3ff0000000000000 },
    .{ .input = 0x3fd62e42fefa39ef, .output = 0x3ff6a09e667f3bcc },
    .{ .input = 0x3ff0a2b23f3bab73, .output = 0x4006a09e667f3bcc },
    .{ .input = 0x400193ea7aad030b, .output = 0x4022000000000001 },
    .{ .input = 0x40026bb1bbb55516, .output = 0x4024000000000001 },
    .{ .input = 0x40062e42fefa39ef, .output = 0x402fffffffffffff },
    .{ .input = 0x400bb9d3beb8c86b, .output = 0x4040000000000000 },
    .{ .input = 0x3ffbb9d3beb8c86b, .output = 0x4016a09e667f3bcc },
    .{ .input = 0x3fe62e42fefa39ef, .output = 0x4000000000000000 },
    .{ .input = 0x3ff62e42fefa39ef, .output = 0x4010000000000000 },
    .{ .input = 0x3ff8000000000000, .output = 0x4011ed3fe64fc542 },
    .{ .input = 0x4000a2b23f3bab73, .output = 0x401ffffffffffffe },
    .{ .input = 0x3c942d169d7dfa04, .output = 0x3ff0000000000000 },
    .{ .input = 0xbc942d169d7dfa04, .output = 0x3fefffffffffffff },
    .{ .input = 0x7ff0000000000000, .output = 0x7ff0000000000000 },
    .{ .input = 0xfff0000000000000, .output = 0x0000000000000000 },
};

const expected_logarithms = [_]Bits{
    .{ .input = 0x3ff0000000000000, .output = 0x0000000000000000 },
    .{ .input = 0x4000000000000000, .output = 0x3fe62e42fefa39ef },
    .{ .input = 0x4008000000000000, .output = 0x3ff193ea7aad030a },
    .{ .input = 0x4010000000000000, .output = 0x3ff62e42fefa39ef },
    .{ .input = 0x4014000000000000, .output = 0x3ff9c041f7ed8d33 },
    .{ .input = 0x401c000000000000, .output = 0x3fff2272ae325a57 },
    .{ .input = 0x4024000000000000, .output = 0x40026bb1bbb55516 },
    .{ .input = 0x402a000000000000, .output = 0x400485042b318c51 },
    .{ .input = 0x4035000000000000, .output = 0x40085b2e946faeb1 },
    .{ .input = 0x4044000000000000, .output = 0x400d82d33b32720d },
    .{ .input = 0x4044800000000000, .output = 0x400db565458eac4e },
    .{ .input = 0x4050000000000000, .output = 0x4010a2b23f3bab73 },
    .{ .input = 0x4059000000000000, .output = 0x40126bb1bbb55516 },
    .{ .input = 0x408f400000000000, .output = 0x401ba18a998fffa0 },
    .{ .input = 0x40c81c8000000000, .output = 0x4022d78e26ae18e8 },
    .{ .input = 0x41efffffffe00000, .output = 0x40362e42fef939ef },
    .{ .input = 0x3fe0000000000000, .output = 0xbfe62e42fefa39ef },
    .{ .input = 0x3fe8000000000000, .output = 0xbfd269621134db92 },
    .{ .input = 0x3fe6a09e667f3bcd, .output = 0xbfd62e42fefa39ee },
    .{ .input = 0x3ff6a09e667f3bcd, .output = 0x3fd62e42fefa39f0 },
    .{ .input = 0x000012688b70e62b, .output = 0xc08628ae3f3c2ff6 },
    .{ .input = 0x0000000000000001, .output = 0xc08628b76e3a7b61 },
    .{ .input = 0x7fe1ccf385ebc8a0, .output = 0x40862991d5d62a5e },
    .{ .input = 0x7fefffffffffffff, .output = 0x40862e42fefa39ef },
    .{ .input = 0x3fb999999999999a, .output = 0xc0026bb1bbb55515 },
    .{ .input = 0x3ff8000000000000, .output = 0x3fd9f323ecbf984c },
    .{ .input = 0x0000000000000000, .output = 0xfff0000000000000 },
    .{ .input = 0x8000000000000000, .output = 0xfff0000000000000 },
    .{ .input = 0xbff0000000000000, .output = 0x7ff8000000000000 },
    .{ .input = 0x7ff0000000000000, .output = 0x7ff0000000000000 },
    .{ .input = 0xfff0000000000000, .output = 0x7ff8000000000000 },
};
