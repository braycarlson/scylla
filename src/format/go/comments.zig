const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../../stdx/bounded/buffer.zig");
const Carry = @import("../align.zig").Carry;
const ascii_whitespace = @import("../../text/scan.zig").ascii_whitespace;
const crosses = @import("../align.zig").crosses;

const Block = struct {
    code: bool,
    end: u32,
    start: u32,
};

const Columns = struct {
    count: u32,
    held: [directive_run_max]bool,
};

const Constraint = struct {
    at: u32,
    count: u32,
    held: [constraint_max]Node,
    line: []const u8,
    tagged: bool,
    token_end: u32,
    token_start: u32,

    const empty: Constraint = .{
        .at = 0,
        .count = 0,
        .held = @splat(.{ .kind = .tag, .left = 0, .right = 0, .text = "" }),
        .line = "",
        .tagged = false,
        .token_end = 0,
        .token_start = 0,
    };

    fn read(constraint: *Constraint, expression: []const u8) ?u32 {
        assert(constraint.count <= constraint_max);
        assert(expression.len < std.math.maxInt(u32));

        constraint.at = 0;
        constraint.line = expression;

        var frames: [constraint_max]Frame = undefined;
        var depth: u32 = 0;

        frames[0] = Frame.empty;

        for (0..expression.len + 1) |_| {
            assert(depth < constraint_max);

            frames[depth].negated = constraint.read_negation() orelse return null;

            if (constraint.token_is("(")) {
                if (depth + 1 == constraint_max) return null;

                depth += 1;
                frames[depth] = Frame.empty;

                continue;
            }

            const atom = constraint.read_tag() orelse return null;
            const step = constraint.read_closed(&frames, &depth, atom) orelse return null;

            switch (step) {
                .more => {},
                .root => |root| return root,
            }
        }

        unreachable;
    }

    fn read_negation(constraint: *Constraint) ?bool {
        if (!constraint.lex()) return null;
        if (!constraint.token_is("!")) return false;
        if (!constraint.lex()) return null;
        if (constraint.token_is("!")) return null;

        assert(constraint.at <= constraint.line.len);

        return true;
    }

    fn read_tag(constraint: *Constraint) ?u32 {
        assert(constraint.token_start <= constraint.token_end);

        if (!constraint.tagged) return null;

        const word = constraint.text();

        assert(valid_tag(word));

        if (!constraint.lex()) return null;
        return constraint.tag(word);
    }

    fn read_closed(
        constraint: *Constraint,
        frames: *[constraint_max]Frame,
        depth: *u32,
        atom: u32,
    ) ?Step {
        assert(depth.* < constraint_max);
        assert(atom < constraint.count);

        var held = atom;

        for (0..constraint_max) |_| {
            const frame = &frames[depth.*];
            if (frame.negated) held = constraint.negate(held) orelse return null;

            if (frame.conjunction) |left| {
                held = constraint.joined(.conjunction, left, held) orelse return null;
            }

            if (constraint.token_is("&&")) {
                frame.conjunction = held;

                return .more;
            }

            frame.conjunction = null;

            if (frame.disjunction) |left| {
                held = constraint.joined(.disjunction, left, held) orelse return null;
            }

            if (constraint.token_is("||")) {
                frame.disjunction = held;

                return .more;
            }

            if (depth.* == 0) {
                if (constraint.text().len > 0) return null;
                return .{ .root = held };
            }

            if (!constraint.token_is(")")) return null;
            if (!constraint.lex()) return null;

            depth.* -= 1;
        }

        unreachable;
    }

    fn read_plus(constraint: *Constraint, arguments: []const u8) ?u32 {
        assert(constraint.count <= constraint_max);
        assert(arguments.len < std.math.maxInt(u32));

        var clauses: ?u32 = null;
        var pieces = std.mem.splitAny(u8, arguments, " \t");

        for (0..arguments.len + 1) |_| {
            const clause = pieces.next() orelse break;
            if (clause.len == 0) continue;

            const found = constraint.read_plus_clause(clause) orelse return null;

            if (clauses) |held| {
                clauses = constraint.joined(.disjunction, held, found) orelse return null;
            } else {
                clauses = found;
            }
        }

        if (clauses) |held| return held;
        return constraint.tag(ignore_tag);
    }

    fn read_plus_clause(constraint: *Constraint, clause: []const u8) ?u32 {
        assert(clause.len > 0);
        assert(std.mem.findAny(u8, clause, " \t") == null);

        var words: ?u32 = null;
        var pieces = std.mem.splitScalar(u8, clause, ',');

        for (0..clause.len + 1) |_| {
            const piece = pieces.next() orelse break;
            const one = constraint.read_plus_word(piece) orelse return null;

            if (words) |held| {
                words = constraint.joined(.conjunction, held, one) orelse return null;
            } else {
                words = one;
            }
        }

        assert(words != null);

        return words;
    }

    fn read_plus_word(constraint: *Constraint, piece: []const u8) ?u32 {
        assert(std.mem.findScalar(u8, piece, ',') == null);

        const doubled = std.mem.startsWith(u8, piece, "!!") or std.mem.eql(u8, piece, "!");
        var negated = false;
        var word = piece;

        if (doubled) {
            word = ignore_tag;
        } else {
            if (std.mem.startsWith(u8, word, "!")) {
                negated = true;
                word = word[1..];
            }

            if (!valid_tag(word)) word = ignore_tag;
        }

        assert(valid_tag(word));

        const one = constraint.tag(word) orelse return null;
        if (!negated) return one;
        return constraint.negate(one);
    }

    fn lowered(constraint: *Constraint, root: u32, budget: u32) ?u32 {
        assert(root < constraint.count);
        assert(budget <= constraint_max);

        var lowering: Lowering = .{
            .task_count = 0,
            .tasks = undefined,
            .value_count = 0,
            .values = undefined,
        };

        lowering.task_push(.{ .visit = .{ .budget = budget, .negated = false, .node = root } });

        for (0..lowering_step_max) |_| {
            const task = lowering.task_pop() orelse break;

            switch (task) {
                .join => |kind| {
                    const right = lowering.value_pop();
                    const left = lowering.value_pop();
                    const held = constraint.joined(kind, left, right) orelse return null;

                    lowering.value_push(held);
                },
                .visit => |visit| {
                    if (!constraint.lowered_visit(&lowering, visit)) return null;
                },
            }
        }

        assert(lowering.task_count == 0);
        assert(lowering.value_count == 1);

        return lowering.values[0];
    }

    fn lowered_visit(constraint: *Constraint, lowering: *Lowering, visit: LoweringVisit) bool {
        assert(visit.node < constraint.count);
        assert(visit.budget <= constraint_max);

        if (visit.budget == 0) return false;

        const one = constraint.held[visit.node];
        const budget = visit.budget - 1;

        switch (one.kind) {
            .tag => {
                if (!visit.negated) {
                    lowering.value_push(visit.node);

                    return true;
                }

                const held = constraint.negate(visit.node) orelse return false;

                lowering.value_push(held);
            },
            .negation => {
                const kept = constraint.held[one.left].kind == .tag and !visit.negated;

                if (kept) {
                    lowering.value_push(visit.node);

                    return true;
                }

                lowering.task_push(.{
                    .visit = .{ .budget = budget, .negated = !visit.negated, .node = one.left },
                });
            },
            .conjunction, .disjunction => {
                const flipped = visit.negated == (one.kind == .conjunction);
                const kind: Operator = if (flipped) .disjunction else .conjunction;

                lowering.task_push(.{ .join = kind });

                lowering.task_push(.{
                    .visit = .{ .budget = budget, .negated = visit.negated, .node = one.right },
                });

                lowering.task_push(.{
                    .visit = .{ .budget = budget, .negated = visit.negated, .node = one.left },
                });
            },
        }

        return true;
    }

    fn lex(constraint: *Constraint) bool {
        assert(constraint.at <= constraint.line.len);

        const source = constraint.line;

        constraint.tagged = false;

        constraint.at += @intCast(std.mem.findNone(u8, source[constraint.at..], " \t") orelse
            source.len - constraint.at);

        const at = constraint.at;

        if (at >= source.len) {
            constraint.token_start = at;
            constraint.token_end = at;

            return true;
        }

        const byte = source[at];
        const doubled = byte == '&' or byte == '|';

        if (doubled) {
            if (at + 1 >= source.len) return false;
            if (source[at + 1] != byte) return false;
        }

        const width: u32 = switch (byte) {
            '(', ')', '!' => 1,
            '&', '|' => 2,
            else => tagged_length(source[at..]),
        };

        if (width == 0) return false;

        constraint.token_start = at;
        constraint.token_end = at + width;
        constraint.at = at + width;
        constraint.tagged = tagging(byte);

        assert(constraint.at <= source.len);
        assert(constraint.token_start < constraint.token_end);

        return true;
    }

    fn token_is(constraint: *const Constraint, word: []const u8) bool {
        assert(word.len > 0);
        assert(constraint.token_end <= constraint.line.len);

        return std.mem.eql(u8, constraint.text(), word);
    }

    fn text(constraint: *const Constraint) []const u8 {
        assert(constraint.token_start <= constraint.token_end);
        assert(constraint.token_end <= constraint.line.len);

        return constraint.line[constraint.token_start..constraint.token_end];
    }

    fn push(constraint: *Constraint, node: Node) ?u32 {
        assert(constraint.count <= constraint_max);

        if (constraint.count >= constraint_max) return null;

        if (node.kind != .tag) assert(node.left < constraint.count);
        if (node.kind == .conjunction) assert(node.right < constraint.count);
        if (node.kind == .disjunction) assert(node.right < constraint.count);

        constraint.held[constraint.count] = node;
        constraint.count += 1;

        assert(constraint.count - 1 < std.math.maxInt(u32));

        return constraint.count - 1;
    }

    fn tag(constraint: *Constraint, word: []const u8) ?u32 {
        assert(word.len > 0);
        assert(constraint.count <= constraint_max);

        return constraint.push(.{ .kind = .tag, .left = 0, .right = 0, .text = word });
    }

    fn joined(constraint: *Constraint, kind: Operator, left: u32, right: u32) ?u32 {
        assert(left < constraint.count);
        assert(right < constraint.count);

        return constraint.push(.{ .kind = kind, .left = left, .right = right, .text = "" });
    }

    fn negate(constraint: *Constraint, held: u32) ?u32 {
        assert(held < constraint.count);
        assert(constraint.count <= constraint_max);

        return constraint.push(.{ .kind = .negation, .left = held, .right = 0, .text = "" });
    }
};

const Frame = struct {
    conjunction: ?u32,
    disjunction: ?u32,
    negated: bool,

    const empty: Frame = .{ .conjunction = null, .disjunction = null, .negated = false };
};

const Lowering = struct {
    task_count: u32,
    tasks: [lowering_task_max]LoweringTask,
    value_count: u32,
    values: [constraint_max + 1]u32,

    fn task_pop(lowering: *Lowering) ?LoweringTask {
        assert(lowering.task_count <= lowering_task_max);

        if (lowering.task_count == 0) return null;

        lowering.task_count -= 1;

        return lowering.tasks[lowering.task_count];
    }

    fn task_push(lowering: *Lowering, task: LoweringTask) void {
        assert(lowering.task_count < lowering_task_max);
        if (task == .visit) assert(task.visit.node < constraint_max);

        switch (task) {
            .join => |kind| assert(kind == .conjunction or kind == .disjunction),
            .visit => |visit| assert(visit.node < constraint_max),
        }

        lowering.tasks[lowering.task_count] = task;
        lowering.task_count += 1;
    }

    fn value_pop(lowering: *Lowering) u32 {
        assert(lowering.value_count > 0);
        assert(lowering.value_count <= lowering.values.len);

        lowering.value_count -= 1;

        return lowering.values[lowering.value_count];
    }

    fn value_push(lowering: *Lowering, value: u32) void {
        assert(lowering.value_count < lowering.values.len);
        assert(value < constraint_max);

        lowering.values[lowering.value_count] = value;
        lowering.value_count += 1;
    }
};

const LoweringTask = union(enum) {
    join: Operator,
    visit: LoweringVisit,
};

const LoweringVisit = struct {
    budget: u32,
    negated: bool,
    node: u32,
};

const Node = struct {
    kind: Operator,
    left: u32,
    right: u32,
    text: []const u8,
};

const Operator = enum(u8) {
    tag,
    negation,
    conjunction,
    disjunction,
};

const Placement = struct {
    goes: [constraint_lines]u32,
    going: u32,
    insert: u32,
    last: u32,
    plus: [constraint_lines]u32,
    plussing: u32,
};

const Rendered = struct {
    budget: u32,
    node: u32,
    rank: Operator,
};

const Rendering = union(enum) {
    close,
    node: Rendered,
    word: Operator,
};

const Run = struct {
    bytes: []const u8,
    directives: bool,
    first: u32,
    from: u32,
    last: u32,
    prefix: u32,
    to: u32,

    fn count(run: *const Run) u32 {
        assert(run.from <= run.to);
        assert(run.to <= run.bytes.len);

        var found: u32 = 0;
        var offset = run.from;

        while (offset < run.to) {
            const end = ended(run.bytes, offset);

            assert(end <= run.to);

            if (!run.skips(run.bytes[offset..end])) found += 1;

            offset = end + 1;
        }

        assert(found <= run.to - run.from);

        return found;
    }

    fn skips(run: *const Run, held: []const u8) bool {
        assert(run.from <= run.to);
        assert(std.mem.findScalar(u8, held, '\n') == null);

        if (!run.directives) return false;
        return directive(held);
    }

    fn line(run: *const Run, index: u32) []const u8 {
        assert(index < std.math.maxInt(u32));

        const held = run.text(index);
        if (held.len < run.prefix) return "";

        const body = held[run.prefix..];
        if (blanked(body)) return "";

        assert(body.len > 0);
        assert(std.mem.findScalar(u8, body, '\n') == null);

        return body;
    }

    fn raw(run: *const Run, index: u32) []const u8 {
        assert(run.from <= run.to);
        assert(run.to <= run.bytes.len);

        var found: u32 = 0;
        var offset = run.from;

        while (offset < run.to) {
            const end = ended(run.bytes, offset);
            const held = run.bytes[offset..end];

            offset = end + 1;

            if (run.skips(held)) continue;
            if (found == index) return held;

            found += 1;
        }

        return "";
    }

    fn text(run: *const Run, index: u32) []const u8 {
        assert(index < std.math.maxInt(u32));

        const whole = run.raw(index);
        const held = whole[@min(comment.len, whole.len)..];

        if (whole.len > 0) assert(std.mem.startsWith(u8, whole, comment));

        assert(std.mem.findScalar(u8, held, '\n') == null);

        if (std.mem.startsWith(u8, held, " ")) return held[1..];
        return held;
    }
};

const Step = union(enum) {
    more,
    root: u32,
};

const Visit = struct {
    budget: u32,
    node: u32,
};

const Walk = struct {
    count: u32,
    visits: [constraint_max + 1]Visit,

    fn init(root: u32, budget: u32) Walk {
        assert(root < constraint_max);
        assert(budget <= constraint_max);

        var walk: Walk = .{ .count = 1, .visits = undefined };

        walk.visits[0] = .{ .budget = budget, .node = root };

        return walk;
    }

    fn leaf(walk: *Walk, constraint: *const Constraint, kind: Operator) error{Overflow}!Visit {
        assert(kind == .conjunction or kind == .disjunction);
        assert(walk.count <= walk.visits.len);

        for (0..constraint_max + 1) |_| {
            assert(walk.count > 0);

            walk.count -= 1;

            const visit = walk.visits[walk.count];
            if (visit.budget == 0) return error.Overflow;

            const one = constraint.held[visit.node];
            if (one.kind != kind) return visit;

            assert(walk.count + 2 <= walk.visits.len);

            walk.visits[walk.count] = .{ .budget = visit.budget - 1, .node = one.right };

            walk.visits[walk.count + 1] = .{ .budget = visit.budget - 1, .node = one.left };
            walk.count += 2;
        }

        unreachable;
    }
};

const comment = "//";
const constraint_lines = 32;
const constraint_max = 128;
const directive_run_max = 256;
const directive_words = [_][]const u8{ "line ", "extern ", "export " };
const document_marks = "*+-";
const go_build = "//go:build";
const ignore_tag = "ignore";
const line_directive = "//line ";
const lowering_step_max = 2 * constraint_max + 1;
const lowering_task_max = 2 * constraint_max + 1;
const plus_build = "+build";
const rendering_step_max = 4 * constraint_max;
const rendering_task_max = 4 * constraint_max;

pub fn documented(bytes: []const u8, out: *Buffer) error{Overflow}!void {
    assert(bytes.len < std.math.maxInt(u32));

    out.clear();

    const count: u32 = @intCast(bytes.len);
    var carry: Carry = .none;
    var offset: u32 = 0;

    while (offset < count) {
        const end = ended(bytes, offset);
        const line = bytes[offset..end];
        const plain = carry != .none or !std.mem.startsWith(u8, line, comment);

        if (plain) {
            carry = crosses(line, carry);

            try out.push(bytes[offset..@min(end + 1, count)]);

            offset = end + 1;

            continue;
        }

        const stop = documented_stop(bytes, offset);
        const edge = @min(stop, count);

        assert(edge > offset);

        const staged = commented(bytes, offset, edge, out) catch false;

        if (!staged) try out.push(bytes[offset..edge]);

        offset = stop;
    }
}

fn documented_stop(bytes: []const u8, offset: u32) u32 {
    assert(offset < bytes.len);
    assert(std.mem.startsWith(u8, bytes[offset..], comment));

    var stop = offset;

    while (stop < bytes.len) {
        const held = ended(bytes, stop);
        if (!std.mem.startsWith(u8, bytes[stop..held], comment)) break;

        stop = held + 1;
    }

    assert(stop > offset);
    assert(stop <= bytes.len + 1);

    return stop;
}

fn commented(bytes: []const u8, from: u32, to: u32, out: *Buffer) error{Overflow}!bool {
    assert(from < to);
    assert(to <= bytes.len);

    if (!documents(bytes, to)) return false;
    return rewritten(bytes, from, to, out);
}

fn documents(bytes: []const u8, to: u32) bool {
    assert(to <= bytes.len);

    if (to >= bytes.len) return false;

    const end = ended(bytes, to);
    const past = bytes[to..end];

    assert(end >= to);

    if (past.len == 0) return false;
    if (past[0] == ' ') return false;
    if (past[0] == '\t') return false;
    if (std.mem.startsWith(u8, past, "/*")) return false;
    return !std.mem.startsWith(u8, past, "import");
}

fn rewritten(bytes: []const u8, from: u32, to: u32, out: *Buffer) error{Overflow}!bool {
    assert(from < to);
    assert(to <= bytes.len);

    var run: Run = .{
        .bytes = bytes,
        .directives = true,
        .first = 0,
        .from = from,
        .last = 0,
        .prefix = 0,
        .to = to,
    };

    const lines = run.count();
    if (lines == 0) return false;

    if (!rewritten_empty(&run, lines)) {
        if (!unindented(&run)) return false;
        if (!spanning(&run)) return false;
    }

    try rewritten_blocks(&run, out);
    try rewritten_directives(bytes, from, to, out);

    return true;
}

fn rewritten_empty(run: *const Run, lines: u32) bool {
    assert(lines > 0);
    assert(run.first == run.last);

    for (0..lines) |index| {
        if (!blanked(run.text(@intCast(index)))) return false;
    }

    return true;
}

fn rewritten_blocks(run: *const Run, out: *Buffer) error{Overflow}!void {
    assert(run.first <= run.last);
    assert(run.from < run.to);

    var blocks: u32 = 0;
    var index = run.first;

    while (index < run.last) {
        index = filled(run, index);

        if (index >= run.last) break;

        const block = spanned(run, index) orelse unreachable;

        if (blocks > 0) try out.push("//\n");

        blocks += 1;

        if (block.code) {
            try coded(run, block.start, block.end, out);
        } else {
            try parted(run, block.start, block.end, out);
        }

        index = block.end;
    }

    assert(blocks <= run.last - run.first);
}

fn rewritten_directives(bytes: []const u8, from: u32, to: u32, out: *Buffer) error{Overflow}!void {
    assert(from < to);
    assert(to <= bytes.len);

    var offset = from;
    var separated = false;

    while (offset < to) {
        const end = ended(bytes, offset);
        const line = bytes[offset..end];

        offset = end + 1;

        if (!directive(line)) continue;

        if (!separated) try out.push("//\n");

        separated = true;

        try out.push(line);
        try out.push("\n");
    }
}

fn unindented(run: *Run) bool {
    assert(run.first == 0);
    assert(run.last == 0);

    const lines = run.count();

    for (0..lines) |index| {
        if (directive(run.raw(@intCast(index)))) return false;
        if (marked(run.text(@intCast(index)))) return false;
    }

    run.first = 0;
    run.last = lines;

    while (run.first < run.last) : (run.first += 1) {
        if (!blanked(run.text(run.first))) break;
    }

    while (run.last > run.first) : (run.last -= 1) {
        if (!blanked(run.text(run.last - 1))) break;
    }

    if (run.first == run.last) return false;

    const head = run.text(run.first);
    var prefix = head[0..spaced(head)];

    for (run.first + 1..run.last) |index| {
        const held = run.text(@intCast(index));
        if (blanked(held)) continue;

        prefix = prefix[0..shared(prefix, held[0..spaced(held)])];
    }

    run.prefix = @intCast(prefix.len);

    assert(run.first < run.last);
    assert(run.last <= lines);

    return true;
}

fn spanning(run: *const Run) bool {
    assert(run.first < run.last);
    assert(run.from < run.to);

    var index = run.first;

    while (index < run.last) {
        index = filled(run, index);

        if (index >= run.last) break;

        const block = spanned(run, index) orelse return false;

        assert(block.end > index);

        index = block.end;
    }

    return true;
}

fn filled(run: *const Run, from: u32) u32 {
    assert(from < run.last);
    assert(run.first <= from);

    var index = from;

    while (index < run.last) : (index += 1) {
        if (run.line(index).len > 0) break;
    }

    return index;
}

fn spanned(run: *const Run, at: u32) ?Block {
    assert(at < run.last);
    assert(run.line(at).len > 0);

    if (spaced(run.line(at)) > 0) return spanned_code(run, at);

    var index = at + 1;

    while (index < run.last) : (index += 1) {
        const held = run.line(index);
        if (held.len == 0) break;
        if (spaced(held) > 0) break;
    }

    if (index < run.last) {
        if (run.line(index).len > 0) {
            const above = run.line(index - 1);
            if (std.mem.endsWith(u8, above, "{")) return null;
            if (std.mem.endsWith(u8, above, "\\")) return null;
        }
    }

    return .{ .code = false, .end = index, .start = at };
}

fn spanned_code(run: *const Run, at: u32) ?Block {
    assert(at < run.last);
    assert(spaced(run.line(at)) > 0);

    var index = at + 1;

    while (index < run.last) : (index += 1) {
        const held = run.line(index);
        if (held.len == 0) continue;
        if (spaced(held) == 0) break;
    }

    var end = index;

    while (end > at) : (end -= 1) {
        if (run.line(end - 1).len > 0) break;
    }

    if (end < run.last) {
        if (std.mem.startsWith(u8, run.line(end), "}")) return null;
    }

    assert(end > at);

    return .{ .code = true, .end = end, .start = at };
}

fn coded(run: *const Run, start: u32, end: u32, out: *Buffer) error{Overflow}!void {
    assert(start < end);
    assert(end <= run.last);

    const head = run.line(start);
    var prefix = head[0..spaced(head)];

    for (start + 1..end) |index| {
        const held = run.line(@intCast(index));
        if (held.len == 0) continue;

        prefix = prefix[0..shared(prefix, held[0..spaced(held)])];
    }

    for (start..end) |index| {
        const held = run.line(@intCast(index));

        if (held.len == 0) {
            try out.push("//\n");

            continue;
        }

        assert(prefix.len <= held.len);

        try out.push("//\t");
        try out.push(held[prefix.len..]);
        try out.push("\n");
    }
}

fn parted(run: *const Run, start: u32, end: u32, out: *Buffer) error{Overflow}!void {
    assert(start < end);
    assert(end <= run.last);

    for (start..end) |index| {
        try out.push("// ");
        try out.push(run.line(@intCast(index)));
        try out.push("\n");
    }
}

fn blanked(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    const result = std.mem.findNone(u8, text, " \t") == null;

    if (result) assert(spaced(text) == text.len);
    if (!result) assert(spaced(text) < text.len);

    return result;
}

fn ended(bytes: []const u8, offset: u32) u32 {
    assert(offset <= bytes.len);
    assert(bytes.len < std.math.maxInt(u32));

    const end = std.mem.findScalarPos(u8, bytes, offset, '\n') orelse bytes.len;

    assert(end >= offset);

    return @intCast(end);
}

fn shared(left: []const u8, right: []const u8) u32 {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    const limit = @min(left.len, right.len);
    const held = std.mem.findDiff(u8, left[0..limit], right[0..limit]) orelse limit;

    assert(held <= limit);
    assert(std.mem.eql(u8, left[0..held], right[0..held]));

    return @intCast(held);
}

fn spaced(text: []const u8) u32 {
    assert(text.len <= std.math.maxInt(u32));

    const held = std.mem.findNone(u8, text, " \t") orelse text.len;

    assert(held <= text.len);
    assert(std.mem.findNone(u8, text[0..held], " \t") == null);

    return @intCast(held);
}

fn directive(line: []const u8) bool {
    assert(std.mem.findScalar(u8, line, '\n') == null);

    if (!std.mem.startsWith(u8, line, comment)) return false;
    return directed(line[comment.len..]);
}

fn directed(text: []const u8) bool {
    assert(std.mem.findScalar(u8, text, '\n') == null);

    for (directive_words) |word| {
        if (std.mem.startsWith(u8, text, word)) return true;
    }

    const colon = std.mem.findScalar(u8, text, ':') orelse return false;
    if (colon == 0) return false;
    if (colon + 1 >= text.len) return false;

    for (text[0 .. colon + 2], 0..) |byte, at| {
        if (at == colon) continue;
        if (std.ascii.isLower(byte)) continue;
        if (!std.ascii.isDigit(byte)) return false;
    }

    return true;
}

fn marked(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    const body = text[spaced(text)..];
    if (body.len == 0) return false;

    const head = body[0];

    assert(head != ' ');
    assert(head != '\t');

    if (std.mem.findScalar(u8, document_marks, head) != null) return true;
    if (head == '#') return true;
    if (std.mem.startsWith(u8, body, "\xE2\x80\xA2")) return true;

    if (head == '[') {
        if (std.mem.findScalar(u8, body, ']')) |at| {
            if (std.mem.startsWith(u8, body[at + 1 ..], ":")) return true;
        }
    }

    const digits = std.mem.findNone(u8, body, "0123456789") orelse body.len;
    if (digits == 0) return false;
    if (digits == body.len) return false;
    return body[digits] == '.' or body[digits] == ')';
}

pub fn built(bytes: []const u8, out: *Buffer) error{Overflow}!void {
    assert(bytes.len < std.math.maxInt(u32));

    out.clear();

    const held = placed(bytes) orelse return out.push(bytes);

    assert(held.insert <= bytes.len);

    try out.push(bytes[0..held.insert]);
    try written_block(bytes, &held, out);
    try built_lines(bytes, &held, out);
}

fn built_lines(bytes: []const u8, held: *const Placement, out: *Buffer) error{Overflow}!void {
    assert(held.insert <= bytes.len);
    assert(held.going + held.plussing > 0);

    var blank = true;
    var offset = held.insert;
    var opened = true;

    while (offset < bytes.len) {
        const end = ended(bytes, offset);
        const line = bytes[offset..end];

        if (dropping(held, offset)) {
            opened = true;
            offset = end + 1;

            continue;
        }

        const empty = line.len == 0;
        const skipped = empty and ((opened and blank) or offset == held.last);

        opened = false;

        if (!skipped) {
            try out.push(line);
            try out.push("\n");

            blank = empty;
        }

        offset = end + 1;
    }
}

fn placed(bytes: []const u8) ?Placement {
    assert(bytes.len < std.math.maxInt(u32));

    var carry: Carry = .none;

    var held: Placement = .{
        .goes = @splat(0),
        .going = 0,
        .insert = 0,
        .last = 0,
        .plus = @splat(0),
        .plussing = 0,
    };

    var leading = true;
    var offset: u32 = 0;

    while (offset < bytes.len) {
        const end = ended(bytes, offset);
        const line = bytes[offset..end];
        const crossed = carry != .none;

        carry = crosses(line, carry);

        const body = std.mem.trimStart(u8, line, ascii_whitespace);

        placed_line(&held, offset, body, crossed);

        if (leading) leading = placed_leading(&held, body, crossed, end);

        offset = end + 1;
    }

    if (held.going == 0) {
        if (held.plussing == 0) return null;
    }

    if (held.going > constraint_lines) return null;
    if (held.plussing > constraint_lines) return null;

    const going_before = held.going > 0 and held.goes[0] < held.insert;
    const plussing_before = held.plussing > 0 and held.plus[0] < held.insert;

    if (going_before) {
        held.insert = held.goes[0];
    } else if (plussing_before) {
        held.insert = held.plus[0];
    } else {}

    assert(held.insert < bytes.len);
    assert(held.going + held.plussing > 0);

    return held;
}

fn placed_line(held: *Placement, offset: u32, body: []const u8, crossed: bool) void {
    assert(held.going + held.plussing <= offset);
    assert(std.mem.findScalar(u8, body, '\n') == null);

    if (!crossed) {
        if (constrained(body) != null) {
            held.goes[@min(held.going, constraint_lines - 1)] = offset;
            held.going += 1;

            return;
        }

        if (plussed(body) != null) {
            held.plus[@min(held.plussing, constraint_lines - 1)] = offset;
            held.plussing += 1;

            return;
        }
    }

    held.last = offset;
}

fn placed_leading(held: *Placement, body: []const u8, crossed: bool, end: u32) bool {
    assert(held.insert <= end + 1);
    assert(body.len <= end);

    if (crossed) return false;

    if (body.len == 0) {
        held.insert = end + 1;

        return true;
    }

    return std.mem.startsWith(u8, body, comment);
}

fn dropping(held: *const Placement, offset: u32) bool {
    assert(held.going <= constraint_lines);
    assert(held.plussing <= constraint_lines);

    if (std.mem.findScalar(u32, held.goes[0..held.going], offset) != null) return true;
    return std.mem.findScalar(u32, held.plus[0..held.plussing], offset) != null;
}

fn written_block(bytes: []const u8, held: *const Placement, out: *Buffer) error{Overflow}!void {
    assert(held.going <= constraint_lines);
    assert(held.plussing <= constraint_lines);
    assert(bytes.len <= std.math.maxInt(u32));

    var constraint: Constraint = .empty;

    const root = written_block_root(bytes, held, &constraint) orelse {
        return written_block_verbatim(bytes, held, out);
    };

    const budget: u32 = constraint_max;

    try out.push("//go:build ");
    try rendered(&constraint, root, .tag, out, budget);
    try out.push("\n");

    if (held.plussing > 0) try written_plus(&constraint, root, out, budget);

    try out.push("\n");
}

fn written_block_root(bytes: []const u8, held: *const Placement, constraint: *Constraint) ?u32 {
    assert(held.going + held.plussing > 0);
    assert(constraint.count == 0);
    assert(bytes.len <= std.math.maxInt(u32));

    if (held.going == 1) {
        const offset = held.goes[0];
        const line = bytes[offset..ended(bytes, offset)];

        const text = constrained(std.mem.trimStart(u8, line, ascii_whitespace)) orelse {
            return null;
        };

        return constraint.read(text);
    }

    if (held.going > 0) return null;

    var root: ?u32 = null;

    for (held.plus[0..held.plussing]) |offset| {
        const line = bytes[offset..ended(bytes, offset)];
        const text = plussed(std.mem.trimStart(u8, line, ascii_whitespace)) orelse return null;
        const one = constraint.read_plus(text) orelse return null;

        if (root) |found| {
            root = constraint.joined(.conjunction, found, one) orelse return null;
        } else {
            root = one;
        }
    }

    return root;
}

fn written_block_verbatim(
    bytes: []const u8,
    held: *const Placement,
    out: *Buffer,
) error{Overflow}!void {
    assert(held.going <= constraint_lines);
    assert(held.plussing <= constraint_lines);
    assert(bytes.len <= std.math.maxInt(u32));

    for (held.goes[0..held.going]) |offset| {
        try out.push(bytes[offset..ended(bytes, offset)]);
        try out.push("\n");
    }

    for (held.plus[0..held.plussing]) |offset| {
        try out.push(bytes[offset..ended(bytes, offset)]);
        try out.push("\n");
    }

    try out.push("\n");
}

fn written_plus(
    constraint: *Constraint,
    node: u32,
    out: *Buffer,
    budget: u32,
) error{Overflow}!void {
    assert(node < constraint.count);
    assert(budget == constraint_max);

    var flat = true;
    var held = constraint.lowered(node, budget);

    if (held) |found| {
        if (!plus_read_ok(constraint, found, budget, &flat)) held = null;
    }

    const root = held orelse {
        return out.push("// +build error: expression too complex for // +build lines\n");
    };

    if (!flat) return plus_lines(constraint, root, out, budget);

    try out.push("// +build ");
    try plus_commas(constraint, root, out, budget);
    try out.push("\n");
}

fn rendered(
    constraint: *const Constraint,
    root: u32,
    rank: Operator,
    out: *Buffer,
    budget: u32,
) error{Overflow}!void {
    assert(root < constraint.count);
    assert(rank != .negation);
    assert(budget < std.math.maxInt(u32));

    var tasks: [rendering_task_max]Rendering = undefined;
    var task_count: u32 = 1;

    tasks[0] = .{ .node = .{ .budget = budget, .node = root, .rank = rank } };

    for (0..rendering_step_max) |_| {
        if (task_count == 0) break;

        task_count -= 1;

        switch (tasks[task_count]) {
            .close => try out.push(")"),
            .node => |task| try rendered_node(constraint, task, out, &tasks, &task_count),
            .word => |kind| try out.push(if (kind == .conjunction) " && " else " || "),
        }
    }

    assert(task_count == 0);
}

fn rendered_node(
    constraint: *const Constraint,
    task: Rendered,
    out: *Buffer,
    tasks: *[rendering_task_max]Rendering,
    task_count: *u32,
) error{Overflow}!void {
    assert(task.node < constraint.count);
    assert(task_count.* + 4 <= rendering_task_max);

    if (task.budget == 0) return error.Overflow;

    const one = constraint.held[task.node];
    const budget = task.budget - 1;
    const inner = constraint.held[one.left].kind;

    const wrapped = switch (one.kind) {
        .tag => false,
        .negation => inner == .conjunction or inner == .disjunction,
        .conjunction, .disjunction => task.rank != .tag and one.kind != task.rank,
    };

    if (one.kind == .tag) return out.push(one.text);

    if (one.kind == .negation) try out.push("!");
    if (wrapped) try out.push("(");

    var count = task_count.*;

    if (wrapped) {
        tasks[count] = .close;
        count += 1;
    }

    if (one.kind == .negation) {
        tasks[count] = .{ .node = .{ .budget = budget, .node = one.left, .rank = .tag } };
        task_count.* = count + 1;

        return;
    }

    tasks[count] = .{ .node = .{ .budget = budget, .node = one.right, .rank = one.kind } };

    tasks[count + 1] = .{ .word = one.kind };
    tasks[count + 2] = .{ .node = .{ .budget = budget, .node = one.left, .rank = one.kind } };
    task_count.* = count + 3;

    assert(task_count.* <= rendering_task_max);
}

fn plus_read_ok(constraint: *const Constraint, root: u32, budget: u32, flat: *bool) bool {
    assert(root < constraint.count);
    assert(budget <= constraint_max);

    var walk = Walk.init(root, budget);

    for (0..constraint_max + 1) |_| {
        if (walk.count == 0) return true;

        const leaf = walk.leaf(constraint, .conjunction) catch return false;

        if (constraint.held[leaf.node].kind == .disjunction) flat.* = false;
        if (!ored_literals(constraint, leaf.node, leaf.budget)) return false;
    }

    unreachable;
}

fn ored_literals(constraint: *const Constraint, root: u32, budget: u32) bool {
    assert(root < constraint.count);
    assert(budget <= constraint_max);

    var walk = Walk.init(root, budget);

    for (0..constraint_max + 1) |_| {
        if (walk.count == 0) return true;

        const leaf = walk.leaf(constraint, .disjunction) catch return false;

        assert(leaf.budget > 0);

        if (!anded_literals(constraint, leaf.node, leaf.budget - 1)) return false;
    }

    unreachable;
}

fn anded_literals(constraint: *const Constraint, root: u32, budget: u32) bool {
    assert(root < constraint.count);
    assert(budget <= constraint_max);

    var walk = Walk.init(root, budget);

    for (0..constraint_max + 1) |_| {
        if (walk.count == 0) return true;

        const leaf = walk.leaf(constraint, .conjunction) catch return false;
        if (!literal(constraint, leaf.node)) return false;
    }

    unreachable;
}

fn literal(constraint: *const Constraint, node: u32) bool {
    assert(node < constraint.count);
    assert(constraint.count <= constraint_max);

    const one = constraint.held[node];
    if (one.kind == .tag) return true;
    if (one.kind != .negation) return false;
    return constraint.held[one.left].kind == .tag;
}

fn plus_lines(
    constraint: *const Constraint,
    root: u32,
    out: *Buffer,
    budget: u32,
) error{Overflow}!void {
    assert(root < constraint.count);
    assert(budget <= constraint_max);

    var walk = Walk.init(root, budget);

    for (0..constraint_max + 1) |_| {
        if (walk.count == 0) return;

        const leaf = try walk.leaf(constraint, .conjunction);

        try out.push("// +build");
        try plus_spaces(constraint, leaf.node, out, leaf.budget);
        try out.push("\n");
    }

    unreachable;
}

fn plus_spaces(
    constraint: *const Constraint,
    root: u32,
    out: *Buffer,
    budget: u32,
) error{Overflow}!void {
    assert(root < constraint.count);
    assert(budget <= constraint_max);

    var walk = Walk.init(root, budget);

    for (0..constraint_max + 1) |_| {
        if (walk.count == 0) return;

        const leaf = try walk.leaf(constraint, .disjunction);

        try out.push(" ");
        try plus_commas(constraint, leaf.node, out, leaf.budget);
    }

    unreachable;
}

fn plus_commas(
    constraint: *const Constraint,
    root: u32,
    out: *Buffer,
    budget: u32,
) error{Overflow}!void {
    assert(root < constraint.count);
    assert(budget <= constraint_max);

    var walk = Walk.init(root, budget);
    var separated = false;

    for (0..constraint_max + 1) |_| {
        if (walk.count == 0) return;

        const leaf = try walk.leaf(constraint, .conjunction);

        if (separated) try out.push(",");

        separated = true;

        try rendered(constraint, leaf.node, .tag, out, leaf.budget);
    }

    unreachable;
}

fn constrained(line: []const u8) ?[]const u8 {
    assert(std.mem.findScalar(u8, line, '\n') == null);

    if (!std.mem.startsWith(u8, line, go_build)) return null;

    const held = line[go_build.len..];
    const trim = std.mem.trim(u8, held, ascii_whitespace);

    if (held.len == trim.len) {
        if (held.len > 0) return null;
    }

    if (trim.len > 0) assert(std.mem.findScalar(u8, ascii_whitespace, trim[0]) == null);

    return trim;
}

fn plussed(line: []const u8) ?[]const u8 {
    assert(std.mem.findScalar(u8, line, '\n') == null);

    if (!std.mem.startsWith(u8, line, comment)) return null;

    const held = std.mem.trim(u8, line[comment.len..], ascii_whitespace);
    if (!std.mem.startsWith(u8, held, plus_build)) return null;

    const rest = held[plus_build.len..];
    const trim = std.mem.trim(u8, rest, ascii_whitespace);

    if (rest.len == trim.len) {
        if (rest.len > 0) return null;
    }

    if (trim.len > 0) assert(std.mem.findScalar(u8, ascii_whitespace, trim[0]) == null);

    return trim;
}

fn tagging(byte: u8) bool {
    if (byte < '.') return false;

    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte >= 0x80;
}

fn tagged_length(text: []const u8) u32 {
    assert(text.len < std.math.maxInt(u32));

    var width: u32 = 0;

    for (text) |byte| {
        if (!tagging(byte)) break;

        width += 1;
    }

    assert(width <= text.len);
    if (width < text.len) assert(!tagging(text[width]));

    return width;
}

fn valid_tag(word: []const u8) bool {
    if (word.len == 0) return false;

    const width = tagged_length(word);

    assert(width <= word.len);

    return width == word.len;
}

pub fn relined(source: []const u8, bytes: []const u8, out: *Buffer) error{Overflow}!void {
    assert(source.len < std.math.maxInt(u32));
    assert(bytes.len < std.math.maxInt(u32));

    out.clear();

    const columns = line_columns(source) orelse return out.push(bytes);
    var carry: Carry = .none;
    var offset: u32 = 0;
    var seen: u32 = 0;

    while (offset < bytes.len) {
        const end = ended(bytes, offset);
        const line = bytes[offset..end];
        const inside = carry != .none;

        carry = crosses(line, carry);

        const body = std.mem.trimStart(u8, line, ascii_whitespace);
        const directed_line = !inside and std.mem.startsWith(u8, body, line_directive);
        const raised = directed_line and seen < columns.count and columns.held[seen];

        if (directed_line) seen += 1;

        try out.push(if (raised) body else line);

        if (end < bytes.len) try out.push("\n");

        offset = end + 1;
    }
}

fn line_columns(source: []const u8) ?Columns {
    assert(source.len < std.math.maxInt(u32));

    var carry: Carry = .none;
    var columns: Columns = .{ .count = 0, .held = @splat(false) };
    var offset: u32 = 0;

    while (offset < source.len) {
        const end = ended(source, offset);
        const line = source[offset..end];
        const inside = carry != .none;

        carry = crosses(line, carry);

        const body = std.mem.trimStart(u8, line, ascii_whitespace);
        const directed_line = !inside and std.mem.startsWith(u8, body, line_directive);

        if (directed_line) {
            if (columns.count == directive_run_max) return null;

            columns.held[columns.count] = std.mem.startsWith(u8, line, line_directive);
            columns.count += 1;
        }

        offset = end + 1;
    }

    assert(columns.count <= directive_run_max);

    return columns;
}

const Case = struct {
    input: []const u8,
    expected: []const u8,
};

test "documented rewrites a doc comment run the way the Rust pass does" {
    const cases = [_]Case{
        .{ .input = "//foo bar\nfunc f() {}\n", .expected = "// foo bar\nfunc f() {}\n" },
        .{
            .input = "// Package p does things.\n//\n// It is good.\npackage p\n",
            .expected = "// Package p does things.\n//\n// It is good.\npackage p\n",
        },
        .{
            .input = "// Example:\n//\n//\tx := 1\n//\ty := 2\nfunc f() {}\n",
            .expected = "// Example:\n//\n//\tx := 1\n//\ty := 2\nfunc f() {}\n",
        },
        .{
            .input = "//  indented two\n//  more\nfunc f() {}\n",
            .expected = "// indented two\n// more\nfunc f() {}\n",
        },
        .{ .input = "//foo\n//bar\ntype T int\n", .expected = "// foo\n// bar\ntype T int\n" },
        .{
            .input = "// Text:\n//\n//     four()\n//     more()\nfunc f() {}\n",
            .expected = "// Text:\n//\n//\tfour()\n//\tmore()\nfunc f() {}\n",
        },
        .{
            .input = "// Text:\n//\n//\t\tdeep\n//\tshallow\nfunc f() {}\n",
            .expected = "// Text:\n//\n//\t\tdeep\n//\tshallow\nfunc f() {}\n",
        },
        .{
            .input = "// Use it:\n//   a()\n//   b()\n// Done.\nvar v int\n",
            .expected = "// Use it:\n//\n//\ta()\n//\tb()\n//\n// Done.\nvar v int\n",
        },
        .{
            .input = "// T:\n//\n//\ta()\n//\n//\tb()\n//\n// End.\nfunc f() {}\n",
            .expected = "// T:\n//\n//\ta()\n//\n//\tb()\n//\n// End.\nfunc f() {}\n",
        },
        .{
            .input = "//   a\n// b\nfunc f() {}\n",
            .expected = "//\ta\n//\n// b\nfunc f() {}\n",
        },
        .{
            .input = "//a\nfunc f() {}\n//b\nfunc g() {}\n",
            .expected = "// a\nfunc f() {}\n// b\nfunc g() {}\n",
        },
    };

    try cases_documented(&cases);
}

test "documented collapses blank comment lines and drops an all blank run" {
    const cases = [_]Case{
        .{
            .input = "// One.\n//\n// Two.\n//\n//\n// Three.\nfunc f() {}\n",
            .expected = "// One.\n//\n// Two.\n//\n// Three.\nfunc f() {}\n",
        },
        .{ .input = "// One.\n//\nfunc f() {}\n", .expected = "// One.\nfunc f() {}\n" },
        .{ .input = "//\n//\nfunc f() {}\n", .expected = "func f() {}\n" },
    };

    try cases_documented(&cases);
}

test "documented moves directives below the text behind a blank comment line" {
    const cases = [_]Case{
        .{
            .input = "// Doc.\n//go:noinline\nfunc f() {}\n",
            .expected = "// Doc.\n//\n//go:noinline\nfunc f() {}\n",
        },
        .{
            .input = "// Doc\n//extern x\nfunc f() {}\n",
            .expected = "// Doc\n//\n//extern x\nfunc f() {}\n",
        },
        .{
            .input = "//go:generate stringer -type=X\nfunc f() {}\n",
            .expected = "//go:generate stringer -type=X\nfunc f() {}\n",
        },
        .{
            .input = "//line foo.go:1\nfunc f() {}\n",
            .expected = "//line foo.go:1\nfunc f() {}\n",
        },
        .{ .input = "//export Foo\nfunc Foo() {}\n", .expected = "//export Foo\nfunc Foo() {}\n" },
        .{
            .input = "//nolint:errcheck\nfunc f() {}\n",
            .expected = "//nolint:errcheck\nfunc f() {}\n",
        },
        .{
            .input = "// see: http://x\nfunc f() {}\n",
            .expected = "// see: http://x\nfunc f() {}\n",
        },
    };

    try cases_documented(&cases);
}

test "documented keeps a run that documents nothing or carries list marks" {
    const cases = [_]Case{
        .{ .input = "// x\n\nfunc f() {}\n", .expected = "// x\n\nfunc f() {}\n" },
        .{ .input = "//foo\nimport \"fmt\"\n", .expected = "//foo\nimport \"fmt\"\n" },
        .{ .input = "//foo\n\tx := 1\n", .expected = "//foo\n\tx := 1\n" },
        .{ .input = "//foo\n/* x */\n", .expected = "//foo\n/* x */\n" },
        .{ .input = "//foo", .expected = "//foo" },
        .{
            .input = "func f() {\n\t//foo\n\tx()\n}\n",
            .expected = "func f() {\n\t//foo\n\tx()\n}\n",
        },
        .{
            .input = "// - item one\n// - item two\nfunc f() {}\n",
            .expected = "// - item one\n// - item two\nfunc f() {}\n",
        },
        .{
            .input = "// 1. first\n// 2. second\nfunc f() {}\n",
            .expected = "// 1. first\n// 2. second\nfunc f() {}\n",
        },
        .{
            .input = "//[link]: http://x\nfunc f() {}\n",
            .expected = "//[link]: http://x\nfunc f() {}\n",
        },
        .{
            .input = "// \xe2\x80\xa2 item\nfunc f() {}\n",
            .expected = "// \xe2\x80\xa2 item\nfunc f() {}\n",
        },
        .{ .input = "// #heading\nfunc f() {}\n", .expected = "// #heading\nfunc f() {}\n" },
    };

    try cases_documented(&cases);
}

test "documented keeps a run whose blocks cannot be told apart" {
    const cases = [_]Case{
        .{
            .input = "//\tcode()\n//\tmore()\n// }\nfunc f() {}\n",
            .expected = "//\tcode()\n//\tmore()\n// }\nfunc f() {}\n",
        },
        .{
            .input = "// open {\n//\tbody\nfunc f() {}\n",
            .expected = "// open {\n//\tbody\nfunc f() {}\n",
        },
        .{
            .input = "// line one \\\n//\tcode\nfunc f() {}\n",
            .expected = "// line one \\\n//\tcode\nfunc f() {}\n",
        },
        .{
            .input = "var s = `\n//foo\n`\nfunc f() {}\n",
            .expected = "var s = `\n//foo\n`\nfunc f() {}\n",
        },
        .{ .input = "/*\n//foo\n*/\nfunc f() {}\n", .expected = "/*\n//foo\n*/\nfunc f() {}\n" },
    };

    try cases_documented(&cases);
}

test "documented reports overflow with the partial output the Rust leaves" {
    var out = try Buffer.init(std.testing.allocator, 8);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectError(error.Overflow, documented("//foo bar\nfunc f() {}\n", &out));
    try std.testing.expectEqualStrings("// ", out.const_slice());

    var wider = try Buffer.init(std.testing.allocator, 24);
    defer wider.deinit(std.testing.allocator);

    const input = "// abc\n//  def\n//  ghi\nfunc f() {}\n";

    try std.testing.expectError(error.Overflow, documented(input, &wider));
    try std.testing.expectEqualStrings("// abc\n//\n//\tdef\n//\tghi\n", wider.const_slice());
}

test "built renders a go:build line and derives the +build lines" {
    const cases = [_]Case{
        .{
            .input = "//go:build linux\n\npackage p\n",
            .expected = "//go:build linux\n\npackage p\n",
        },
        .{
            .input = "// +build linux darwin\n\npackage p\n",
            .expected = "//go:build linux || darwin\n// +build linux darwin\n\npackage p\n",
        },
        .{
            .input = "//go:build linux && !cgo\n// +build linux,!cgo\n\npackage p\n",
            .expected = "//go:build linux && !cgo\n// +build linux,!cgo\n\npackage p\n",
        },
        .{
            .input = "//go:build (linux || darwin) && amd64\n\npackage p\n",
            .expected = "//go:build (linux || darwin) && amd64\n\npackage p\n",
        },
        .{
            .input = "//go:build (linux || darwin) && amd64\n// +build linux darwin\n" ++
                "// +build amd64\n\npackage p\n",
            .expected = "//go:build (linux || darwin) && amd64\n// +build linux darwin\n" ++
                "// +build amd64\n\npackage p\n",
        },
        .{
            .input = "// +build !windows\n// +build amd64\n\npackage p\n",
            .expected = "//go:build !windows && amd64\n// +build !windows,amd64\n\npackage p\n",
        },
        .{
            .input = "//go:build !(linux && amd64)\n// +build !linux !amd64\n\npackage p\n",
            .expected = "//go:build !(linux && amd64)\n// +build !linux !amd64\n\npackage p\n",
        },
        .{
            .input = "// +build linux,386 darwin,!cgo\n\npackage p\n",
            .expected = "//go:build (linux && 386) || (darwin && !cgo)\n" ++
                "// +build linux,386 darwin,!cgo\n\npackage p\n",
        },
        .{
            .input = "//go:build (a && b) || (c && !d)\n// +build x\n\npackage p\n",
            .expected = "//go:build (a && b) || (c && !d)\n// +build a,b c,!d\n\npackage p\n",
        },
        .{
            .input = "//go:build !(!(a))\n// +build x\n\npackage p\n",
            .expected = "//go:build !!a\n// +build a\n\npackage p\n",
        },
    };

    try cases_built(&cases);
}

test "built re-renders the spacing and nesting of a go:build expression" {
    const cases = [_]Case{
        .{
            .input = "//go:build ((((a))))\n\npackage p\n",
            .expected = "//go:build a\n\npackage p\n",
        },
        .{
            .input = "//go:build a0&&b1\n\npackage p\n",
            .expected = "//go:build a0 && b1\n\npackage p\n",
        },
        .{
            .input = "//go:build a ||b\n\npackage p\n",
            .expected = "//go:build a || b\n\npackage p\n",
        },
        .{
            .input = "//go:build \xc3\xa9t\xc3\xa9 && go1.18\n// +build x\n\npackage p\n",
            .expected = "//go:build \xc3\xa9t\xc3\xa9 && go1.18\n" ++
                "// +build \xc3\xa9t\xc3\xa9,go1.18\n\npackage p\n",
        },
        .{
            .input = "//go:build !(a || b) && c\n// +build x\n\npackage p\n",
            .expected = "//go:build !(a || b) && c\n// +build !a,!b,c\n\npackage p\n",
        },
        .{
            .input = "//go:build a && (b || c) && !d\n// +build x\n\npackage p\n",
            .expected = "//go:build a && (b || c) && !d\n// +build a\n// +build b c\n" ++
                "// +build !d\n\npackage p\n",
        },
        .{
            .input = "//go:build a || b && c || d\n// +build x\n\npackage p\n",
            .expected = "//go:build a || (b && c) || d\n// +build a b,c d\n\npackage p\n",
        },
        .{
            .input = "// +build a b\n// +build c\n// +build !d,e\n\npackage p\n",
            .expected = "//go:build (a || b) && c && !d && e\n// +build a b\n// +build c\n" ++
                "// +build !d\n// +build e\n\npackage p\n",
        },
        .{
            .input = "//go:buildlinux \n\npackage p\n",
            .expected = "//go:build linux\n\npackage p\n",
        },
    };

    try cases_built(&cases);
}

test "built reads +build arguments the way the Go tool does" {
    const cases = [_]Case{
        .{
            .input = "// +build !!x\n\npackage p\n",
            .expected = "//go:build ignore\n// +build ignore\n\npackage p\n",
        },
        .{
            .input = "//   +build linux\n\npackage p\n",
            .expected = "//go:build linux\n// +build linux\n\npackage p\n",
        },
        .{
            .input = "// +build\tlinux\n\npackage p\n",
            .expected = "//go:build linux\n// +build linux\n\npackage p\n",
        },
        .{
            .input = "// +build\n\npackage p\n",
            .expected = "//go:build ignore\n// +build ignore\n\npackage p\n",
        },
        .{
            .input = "// +build lin#ux !\n\npackage p\n",
            .expected = "//go:build ignore || ignore\n// +build ignore ignore\n\npackage p\n",
        },
        .{
            .input = "// +build linux\n//go:build linux\n\npackage p\n",
            .expected = "// +build linux\n//go:build linux\n// +build linux\n\npackage p\n",
        },
    };

    try cases_built(&cases);
}

test "built places the block and drops the blank lines it leaves" {
    const cases = [_]Case{
        .{ .input = "package p\n", .expected = "package p\n" },
        .{
            .input = "// Package p does.\n\n//go:build linux\n\npackage p\n",
            .expected = "// Package p does.\n\n//go:build linux\n\npackage p\n",
        },
        .{
            .input = "//go:build linux\n\npackage p\n\n",
            .expected = "//go:build linux\n\npackage p\n",
        },
        .{
            .input = "package p\n\n//go:build linux\n",
            .expected = "//go:build linux\n\npackage p\n",
        },
        .{
            .input = "  //go:build linux\n\npackage p\n",
            .expected = "//go:build linux\n\npackage p\n",
        },
        .{
            .input = "//go:build linux\n\n\n\npackage p\n\n\nfunc f() {}\n",
            .expected = "//go:build linux\n\n\n\npackage p\n\n\nfunc f() {}\n",
        },
        .{
            .input = "// Copyright.\n//go:build linux\n// More.\n\npackage p\n",
            .expected = "// Copyright.\n//go:build linux\n\n// More.\n\npackage p\n",
        },
        .{
            .input = "package p\n\nvar s = `\n//go:build linux\n`\n",
            .expected = "package p\n\nvar s = `\n//go:build linux\n`\n",
        },
        .{ .input = "//go:build linux\n   ", .expected = "//go:build linux\n\n   \n" },
    };

    try cases_built(&cases);
}

test "built keeps constraints it cannot read verbatim" {
    const cases = [_]Case{
        .{
            .input = "//go:build linux\n//go:build darwin\n\npackage p\n",
            .expected = "//go:build linux\n//go:build darwin\n\npackage p\n",
        },
        .{
            .input = "//go:build linux &\n\npackage p\n",
            .expected = "//go:build linux &\n\npackage p\n",
        },
        .{
            .input = "//go:buildlinux\n\npackage p\n",
            .expected = "//go:buildlinux\n\npackage p\n",
        },
        .{
            .input = "//go:build a | b\n\npackage p\n",
            .expected = "//go:build a | b\n\npackage p\n",
        },
        .{
            .input = "//go:build a &&\n\npackage p\n",
            .expected = "//go:build a &&\n\npackage p\n",
        },
        .{ .input = "//go:build (a\n\npackage p\n", .expected = "//go:build (a\n\npackage p\n" },
        .{ .input = "//go:build a)\n\npackage p\n", .expected = "//go:build a)\n\npackage p\n" },
        .{ .input = "//go:build !\n\npackage p\n", .expected = "//go:build !\n\npackage p\n" },
        .{ .input = "//go:build ()\n\npackage p\n", .expected = "//go:build ()\n\npackage p\n" },
        .{ .input = "//go:build a b\n\npackage p\n", .expected = "//go:build a b\n\npackage p\n" },
        .{ .input = "//go:build\n\npackage p\n", .expected = "//go:build\n\npackage p\n" },
        .{ .input = "//go:build !!a\n\npackage p\n", .expected = "//go:build !!a\n\npackage p\n" },
        .{
            .input = "//go:build (a || b) && c || d\n// +build x\n\npackage p\n",
            .expected = "//go:build ((a || b) && c) || d\n" ++
                "// +build error: expression too complex for // +build lines\n\npackage p\n",
        },
    };

    try cases_built(&cases);
}

test "built stops at the parenthesis depth and node count of the Rust tables" {
    var input = try Buffer.init(std.testing.allocator, 4096);
    defer input.deinit(std.testing.allocator);

    var out = try Buffer.init(std.testing.allocator, 4096);
    defer out.deinit(std.testing.allocator);

    for ([_]u32{ 127, 128, 130 }) |depth| {
        input.clear();

        try input.push("//go:build ");

        for (0..depth) |_| try input.push("(");

        try input.push("a");

        for (0..depth) |_| try input.push(")");

        try input.push("\n\npackage p\n");
        try built(input.const_slice(), &out);

        const expected = if (depth == 127) "//go:build a\n\npackage p\n" else input.const_slice();

        try std.testing.expectEqualStrings(expected, out.const_slice());
    }

    var expected = try Buffer.init(std.testing.allocator, 4096);
    defer expected.deinit(std.testing.allocator);

    for ([_]u32{ 64, 70 }) |tags| {
        input.clear();
        expected.clear();

        try input.push("//go:build a0");
        try expected.push("//go:build a0");

        for (1..tags) |index| {
            var digits: [16]u8 = undefined;
            const tight = try std.mem.print(&digits, "||a{d}", .{index});

            try input.push(tight);

            const spaced_tag = try std.mem.print(&digits, " || a{d}", .{index});

            try expected.push(spaced_tag);
        }

        try input.push("\n\npackage p\n");
        try expected.push("\n\npackage p\n");
        try built(input.const_slice(), &out);

        const verbatim = tags == 70;

        if (verbatim) try std.testing.expectEqualStrings(input.const_slice(), out.const_slice());

        if (!verbatim) {
            try std.testing.expectEqualStrings(expected.const_slice(), out.const_slice());
        }
    }
}

test "built writes the +build error line when lowering outgrows the node table" {
    var input = try Buffer.init(std.testing.allocator, 4096);
    defer input.deinit(std.testing.allocator);

    var expected = try Buffer.init(std.testing.allocator, 4096);
    defer expected.deinit(std.testing.allocator);

    var out = try Buffer.init(std.testing.allocator, 4096);
    defer out.deinit(std.testing.allocator);

    try input.push("//go:build a0");

    for (1..64) |index| {
        var digits: [8]u8 = undefined;
        const tag = try std.mem.print(&digits, " || a{d}", .{index});

        try input.push(tag);
    }

    try expected.push(input.const_slice());
    try expected.push("\n// +build error: expression too complex for // +build lines\n");
    try expected.push("\npackage p\n");
    try input.push("\n// +build x\n\npackage p\n");
    try built(input.const_slice(), &out);
    try std.testing.expectEqualStrings(expected.const_slice(), out.const_slice());
}

test "built keeps more constraint lines than the placement holds" {
    var input = try Buffer.init(std.testing.allocator, 4096);
    defer input.deinit(std.testing.allocator);

    var out = try Buffer.init(std.testing.allocator, 4096);
    defer out.deinit(std.testing.allocator);

    for (0..33) |index| {
        var line: [24]u8 = undefined;
        const held = try std.mem.print(&line, "//go:build a{d}\n", .{index});

        try input.push(held);
    }

    try input.push("\npackage p\n");
    try built(input.const_slice(), &out);
    try std.testing.expectEqualStrings(input.const_slice(), out.const_slice());
}

test "built reports overflow" {
    var out = try Buffer.init(std.testing.allocator, 12);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectError(error.Overflow, built("//go:build linux\n\npackage p\n", &out));
    try std.testing.expectEqualStrings("//go:build ", out.const_slice());
}

test "relined raises the line directives the source held at the first column" {
    const Relining = struct {
        source: []const u8,
        input: []const u8,
        expected: []const u8,
    };

    const cases = [_]Relining{
        .{
            .source = "package p\n//line foo.go:10\nvar x int\n",
            .input = "package p\n\t//line foo.go:10\nvar x int\n",
            .expected = "package p\n//line foo.go:10\nvar x int\n",
        },
        .{
            .source = "package p\n\t//line foo.go:10\nvar x int\n",
            .input = "package p\n\t//line foo.go:10\nvar x int\n",
            .expected = "package p\n\t//line foo.go:10\nvar x int\n",
        },
        .{
            .source = "package p\n",
            .input = "package p\nvar x int\n",
            .expected = "package p\nvar x int\n",
        },
        .{
            .source = "//line a.go:1\nvar x int",
            .input = "\t//line a.go:1\nvar x int",
            .expected = "//line a.go:1\nvar x int",
        },
        .{
            .source = "var s = `\n//line a.go:1\n`\n",
            .input = "var s = `\n\t//line a.go:1\n`\n",
            .expected = "var s = `\n\t//line a.go:1\n`\n",
        },
        .{
            .source = "//line a.go:1\n",
            .input = "\t//line a.go:1\n\t//line b.go:2\n",
            .expected = "//line a.go:1\n\t//line b.go:2\n",
        },
        .{
            .source = "//line a.go:1\n\t//line b.go:2\n//line c.go:3\n",
            .input = "\t//line a.go:1\n\t//line b.go:2\n\t//line c.go:3\n",
            .expected = "//line a.go:1\n\t//line b.go:2\n//line c.go:3\n",
        },
    };

    var out = try Buffer.init(std.testing.allocator, 4096);
    defer out.deinit(std.testing.allocator);

    for (cases) |case| {
        try relined(case.source, case.input, &out);
        try std.testing.expectEqualStrings(case.expected, out.const_slice());
    }
}

test "relined copies the bytes when the source holds too many directives" {
    var source = try Buffer.init(std.testing.allocator, 8192);
    defer source.deinit(std.testing.allocator);

    var out = try Buffer.init(std.testing.allocator, 4096);
    defer out.deinit(std.testing.allocator);

    for (0..257) |_| try source.push("//line a.go:1\n");

    try relined(source.const_slice(), "\t//line a.go:1\n", &out);
    try std.testing.expectEqualStrings("\t//line a.go:1\n", out.const_slice());

    var small = try Buffer.init(std.testing.allocator, 10);
    defer small.deinit(std.testing.allocator);

    const input = "\t//line a.go:1\nvar x int\n";

    try std.testing.expectError(error.Overflow, relined("//line a.go:1\n", input, &small));
    try std.testing.expectEqualStrings("", small.const_slice());
}

fn cases_documented(cases: []const Case) !void {
    assert(cases.len <= std.math.maxInt(u32));

    var out = try Buffer.init(std.testing.allocator, 4096);
    defer out.deinit(std.testing.allocator);

    for (cases) |case| {
        try documented(case.input, &out);
        try std.testing.expectEqualStrings(case.expected, out.const_slice());
    }
}

fn cases_built(cases: []const Case) !void {
    assert(cases.len <= std.math.maxInt(u32));

    var out = try Buffer.init(std.testing.allocator, 4096);
    defer out.deinit(std.testing.allocator);

    for (cases) |case| {
        try built(case.input, &out);
        try std.testing.expectEqualStrings(case.expected, out.const_slice());
    }
}
