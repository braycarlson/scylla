const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../../stdx/bounded/buffer.zig");
const Index = @import("../../text/line_index.zig").LineIndex;
const Kind = @import("../../syntax/python/kind.zig").Kind;
const Semantic = @import("../../syntax/python/semantic.zig").Semantic;
const Span = @import("../../stdx/bounded/span.zig");
const Style = @import("../../syntax/python/style.zig").Style;
const Token = @import("../../syntax/token.zig");
const TreeType = @import("../../syntax/tree.zig").TreeType;
const sorting = @import("../../stdx/sort.zig");
const stdlib = @import("../../syntax/python/stdlib.zig");
const Order = std.math.Order;
const Tree = TreeType(Kind);
pub const Error = error{ Overflow, Refused };

pub const Parsed = struct {
    index: *const Index,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
};

pub const Insertion = struct {
    leading: u32,
    offset: u32,
};

pub const Symbol = union(enum) {
    bound: u32,
    insert: Insertion,
};

pub const Section = enum(u8) {
    future,
    standard_library,
    third_party,
    first_party,
    local_folder,
};

pub const Block = struct {
    span: Span,
    statement_first: u32,
    statement_last: u32,
};

const MemberType = enum(u8) {
    constant,
    class,
    variable,
};

const Header = struct {
    level: u32,
    module: Span,
};

const ImportPath = struct {
    member: Span,
    module: Span,
};

const Row = struct {
    as_name: Span,
    from: bool,
    level: u32,
    module: Span,
    name: Span,
    section: Section,
    trailing_comma: bool,
};

pub const import_count_max: u32 = 1 << 8;

const row_empty: Row = .{
    .as_name = .empty,
    .from = false,
    .level = 0,
    .module = .empty,
    .name = .empty,
    .section = .third_party,
    .trailing_comma = false,
};

pub fn insertion_point(tokens: []const Token, tree: *const Tree, index: *const Index) Insertion {
    assert(tokens.len <= std.math.maxInt(u32));

    if (tree.count() == 0) return .{ .leading = 0, .offset = 0 };

    var import_last: ?u32 = null;
    var child = tree.child_first_of(0);

    for (0..tree.count()) |_| {
        const node = child orelse break;
        const imports = is_import(tree.kind_at(node));

        if (!imports) {
            if (import_last != null) break;
            if (!is_docstring(tree, node)) break;
        }

        if (imports) import_last = node;

        child = tree.sibling_next_of(node);
    }

    if (import_last) |node| {
        assert(is_import(tree.kind_at(node)));

        return .{ .leading = 0, .offset = after_line_of(tree, tokens, index, node) };
    }

    const head = tree.child_first_of(0) orelse return .{ .leading = 0, .offset = 0 };

    if (is_docstring(tree, head)) {
        return .{ .leading = 1, .offset = after_line_of(tree, tokens, index, head) };
    }

    return .{ .leading = 0, .offset = 0 };
}

pub fn symbol_of(
    parsed: *const Parsed,
    semantic: *const Semantic,
    module: []const u8,
    member: []const u8,
    out: *ArrayType(Span),
) error{Overflow}!Symbol {
    assert(module.len > 0);
    assert(member.len > 0);

    out.clear();

    const bindings = semantic.binding_slice();
    var iterator = semantic.bindings_of(0);

    for (0..bindings.len + 1) |_| {
        const binding = iterator.next() orelse break;
        const held = bindings[binding];
        if (!held.kind.imports()) continue;

        const path = import_path_of(parsed, held.node, module, member) orelse continue;

        if (out.unused_capacity() < 2) return error.Overflow;

        out.push(path.module);
        out.push(path.member);

        return .{ .bound = binding };
    }

    assert(out.empty());

    return .{ .insert = insertion_point(parsed.tokens, parsed.tree, parsed.index) };
}

pub fn blocks(
    tokens: []const Token,
    tree: *const Tree,
    index: *const Index,
    out: *ArrayType(Block),
) error{Overflow}!void {
    out.clear();

    assert(out.empty());
    assert(tokens.len <= std.math.maxInt(u32));

    if (tree.count() == 0) return;

    var statement_first: ?u32 = null;
    var statement_last: u32 = 0;
    var child = tree.child_first_of(0);

    for (0..tree.count()) |_| {
        const node = child orelse break;

        child = tree.sibling_next_of(node);

        if (is_import(tree.kind_at(node))) {
            if (statement_first == null) statement_first = node;

            statement_last = node;

            continue;
        }

        if (statement_first) |head| try push_block(tokens, tree, index, head, statement_last, out);

        statement_first = null;
    }

    assert(child == null);

    const head = statement_first orelse return;

    try push_block(tokens, tree, index, head, statement_last, out);
}

pub fn sort(
    parsed: *const Parsed,
    block: *const Block,
    modules_first_party: []const []const u8,
    style: Style,
    line_width: u32,
    out: *Buffer,
) Error!void {
    assert(line_width > 0);
    assert(block.span.end() <= parsed.source.len);
    assert(modules_first_party.len <= std.math.maxInt(u32));
    assert(style.line_ending.bytes().len > 0);

    out.clear();
    errdefer out.clear();

    if (std.mem.findScalar(u8, block.span.text(parsed.source), '#') != null) {
        return error.Refused;
    }

    if (shares_a_line(parsed, block)) return error.Refused;

    var rows: [import_count_max]Row = @splat(row_empty);
    const row_count = try collect_rows(parsed, block, modules_first_party, &rows);

    sorting.unstable(Row, rows[0..row_count], []const u8, parsed.source, row_less);

    const kept = deduplicated(parsed.source, rows[0..row_count]);

    assert(kept <= row_count);

    try render_rows(parsed.source, rows[0..kept], style, line_width, out);
}

fn is_import(kind: Kind) bool {
    if (!kind.is_node()) return false;

    const result = kind == .import or kind == .import_from;

    if (kind == .alias) assert(!result);

    return result;
}

fn is_docstring(tree: *const Tree, node: u32) bool {
    assert(node < tree.count());

    if (tree.kind_at(node) != .expr) return false;

    const child = tree.child_first_of(node) orelse return false;

    assert(child > node);

    return tree.kind_at(child) == .constant;
}

fn after_line_of(tree: *const Tree, tokens: []const Token, index: *const Index, node: u32) u32 {
    assert(node < tree.count());
    assert(tokens.len <= std.math.maxInt(u32));

    const span = tree.at(node).span(Token, tokens);
    const line = index.line_of(span.end() -| 1);

    if (line + 1 < index.count()) {
        const start = index.line_start(line + 1);

        assert(start >= span.end());

        return start;
    }

    return span.end();
}

fn shares_a_line(parsed: *const Parsed, block: *const Block) bool {
    const head = parsed.tree.at(block.statement_first).span(Token, parsed.tokens);
    const tail = parsed.tree.at(block.statement_last).span(Token, parsed.tokens);
    const line_start = parsed.index.line_start(parsed.index.line_of(head.offset));

    const line_end = after_line_of(
        parsed.tree,
        parsed.tokens,
        parsed.index,
        block.statement_last,
    );

    assert(line_start <= head.offset);
    assert(tail.end() <= line_end);

    if (!is_blank(parsed.source[line_start..head.offset])) return true;
    return !is_blank(parsed.source[tail.end()..line_end]);
}

fn is_blank(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    for (bytes) |byte| {
        const blank = switch (byte) {
            '\t', '\n', '\r', ' ' => true,
            else => false,
        };

        if (!blank) return false;
    }

    return true;
}

fn import_path_of(
    parsed: *const Parsed,
    alias: u32,
    module: []const u8,
    member: []const u8,
) ?ImportPath {
    assert(alias < parsed.tree.count());
    assert(module.len <= std.math.maxInt(u32));
    assert(member.len <= std.math.maxInt(u32));

    const parent = parsed.tree.parent_of(alias) orelse return null;
    const path = path_of_alias(parsed, alias);

    assert(parent < alias);
    assert(path.end() <= parsed.source.len);

    if (parsed.tree.kind_at(parent) == .import_from) {
        const header = header_of(parsed, parent);
        if (header.level != 0) return null;
        if (!std.mem.eql(u8, header.module.text(parsed.source), module)) return null;
        if (!std.mem.eql(u8, path.text(parsed.source), member)) return null;
        return .{ .member = path, .module = header.module };
    }

    const text = path.text(parsed.source);
    if (text.len != module.len + member.len + 1) return null;
    if (!std.mem.startsWith(u8, text, module)) return null;
    if (text[module.len] != '.') return null;
    if (!std.mem.eql(u8, text[module.len + 1 ..], member)) return null;

    const module_length: u32 = @intCast(module.len);

    return .{
        .member = .{ .offset = path.offset + module_length + 1, .length = @intCast(member.len) },
        .module = .{ .offset = path.offset, .length = module_length },
    };
}

fn path_of_alias(parsed: *const Parsed, alias: u32) Span {
    assert(alias < std.math.maxInt(u32));

    const held = parsed.tree.at(alias);
    var end = held.token_end;

    assert(held.token_start <= held.token_end);

    for (held.token_start..held.token_end) |position| {
        if (std.mem.eql(u8, parsed.tokens[position].text(parsed.source), "as")) {
            end = @intCast(position);

            break;
        }
    }

    assert(end <= held.token_end);

    return span_over(parsed.tokens, held.token_start, end);
}

fn header_of(parsed: *const Parsed, statement: u32) Header {
    assert(statement < std.math.maxInt(u32));

    const held = parsed.tree.at(statement);
    var level: u32 = 0;
    var start = held.token_start + 1;
    var end = start;

    assert(held.token_start < held.token_end);

    for (held.token_start + 1..held.token_end) |position| {
        const text = parsed.tokens[position].text(parsed.source);
        const dots = std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "...");

        if (std.mem.eql(u8, text, "import")) break;

        if (dots) {
            level += @intCast(text.len);
            start = @intCast(position + 1);
            end = start;

            continue;
        }

        end = @intCast(position + 1);
    }

    assert(start <= end);

    return .{ .level = level, .module = span_over(parsed.tokens, start, end) };
}

fn has_trailing_comma(parsed: *const Parsed, statement: u32) bool {
    assert(statement < std.math.maxInt(u32));

    const held = parsed.tree.at(statement);

    assert(held.token_start <= held.token_end);
    assert(held.token_end <= parsed.tokens.len);

    for (0..held.token_end - held.token_start) |step| {
        const position = held.token_end - 1 - @as(u32, @intCast(step));
        const token = parsed.tokens[position];
        if (token.kind == .newline) continue;
        if (!token.is_punctuation(.paren_close)) return false;
        if (position == held.token_start) return false;
        return parsed.tokens[position - 1].is_punctuation(.comma);
    }

    return false;
}

fn span_over(tokens: []const Token, start: u32, end: u32) Span {
    assert(start < tokens.len);
    assert(end < std.math.maxInt(u32));

    if (end <= start) return .empty;

    assert(end <= tokens.len);

    const offset = tokens[start].offset;
    const stop = tokens[end - 1].end();

    assert(stop >= offset);

    return .{ .offset = offset, .length = stop - offset };
}

fn push_block(
    tokens: []const Token,
    tree: *const Tree,
    index: *const Index,
    statement_first: u32,
    statement_last: u32,
    out: *ArrayType(Block),
) error{Overflow}!void {
    assert(statement_first <= statement_last);
    assert(tokens.len <= std.math.maxInt(u32));

    const head = tree.at(statement_first).span(Token, tokens);
    const start = index.line_start(index.line_of(head.offset));
    const end = after_line_of(tree, tokens, index, statement_last);

    assert(start <= end);

    if (out.full()) return error.Overflow;

    out.push(.{
        .span = .{ .offset = start, .length = end - start },
        .statement_first = statement_first,
        .statement_last = statement_last,
    });
}

fn collect_rows(
    parsed: *const Parsed,
    block: *const Block,
    modules_first_party: []const []const u8,
    rows: *[import_count_max]Row,
) Error!u32 {
    assert(modules_first_party.len <= std.math.maxInt(u32));

    var row_count: u32 = 0;
    var statement = block.statement_first;

    assert(block.statement_first <= block.statement_last);

    for (0..parsed.tree.count() + 1) |_| {
        assert(statement <= block.statement_last);
        assert(is_import(parsed.tree.kind_at(statement)));

        const header: Header = if (parsed.tree.kind_at(statement) == .import_from)
            header_of(parsed, statement)
        else
            .{ .level = 0, .module = .empty };

        row_count = try statement_rows(
            parsed,
            statement,
            header,
            modules_first_party,
            rows,
            row_count,
        );

        if (statement == block.statement_last) return row_count;

        statement = parsed.tree.sibling_next_of(statement) orelse return row_count;
    }

    unreachable;
}

fn statement_rows(
    parsed: *const Parsed,
    statement: u32,
    header: Header,
    modules_first_party: []const []const u8,
    rows: *[import_count_max]Row,
    at: u32,
) Error!u32 {
    assert(statement < std.math.maxInt(u32));
    assert(modules_first_party.len <= std.math.maxInt(u32));
    assert(at <= import_count_max);

    const from = parsed.tree.kind_at(statement) == .import_from;
    const trailing_comma = from and has_trailing_comma(parsed, statement);
    var row_count = at;
    var child = parsed.tree.child_first_of(statement);

    if (!from) assert(header.level == 0);

    for (0..parsed.tree.count()) |_| {
        const node = child orelse break;

        child = parsed.tree.sibling_next_of(node);

        if (parsed.tree.kind_at(node) != .alias) continue;
        if (row_count == import_count_max) return error.Refused;

        const path = path_of_alias(parsed, node);
        if (std.mem.eql(u8, path.text(parsed.source), "*")) return error.Refused;

        const module = if (from) header.module else path;
        const module_text = module.text(parsed.source);
        const section = section_of(module_text, header.level, modules_first_party);

        rows[row_count] = .{
            .as_name = as_name_of(parsed, node),
            .from = from,
            .level = header.level,
            .module = module,
            .name = if (from) path else .empty,
            .section = section,
            .trailing_comma = trailing_comma,
        };

        row_count += 1;
    }

    assert(row_count >= at);

    return row_count;
}

fn as_name_of(parsed: *const Parsed, alias: u32) Span {
    assert(alias < std.math.maxInt(u32));

    const held = parsed.tree.at(alias);

    assert(held.kind == .alias);
    assert(held.token_start <= held.token_end);

    for (held.token_start..held.token_end) |position| {
        if (std.mem.eql(u8, parsed.tokens[position].text(parsed.source), "as")) {
            return span_over(parsed.tokens, @as(u32, @intCast(position)) + 1, held.token_end);
        }
    }

    return .empty;
}

fn section_of(
    module: []const u8,
    level: u32,
    modules_first_party: []const []const u8,
) Section {
    assert(module.len <= std.math.maxInt(u32));
    assert(modules_first_party.len <= std.math.maxInt(u32));

    if (std.mem.eql(u8, module, "__future__")) return .future;
    if (level > 0) return .local_folder;

    const head_length = std.mem.findScalar(u8, module, '.') orelse module.len;
    const head = module[0..head_length];

    assert(head.len <= module.len);

    for (modules_first_party) |party| {
        if (std.mem.eql(u8, party, head)) return .first_party;
    }

    if (stdlib.is_module(module)) return .standard_library;
    return .third_party;
}

fn row_less(source: []const u8, left: Row, right: Row) bool {
    assert(left.module.end() <= source.len);
    assert(right.module.end() <= source.len);

    return order_of(source, left, right) == .lt;
}

fn order_of(source: []const u8, left: Row, right: Row) Order {
    assert(left.name.end() <= source.len);
    assert(right.name.end() <= source.len);

    const left_module = left.module.text(source);
    const right_module = right.module.text(source);
    const left_name = left.name.text(source);
    const right_name = right.name.text(source);
    const left_type = @backingInt(member_type_of(left_name));
    const right_type = @backingInt(member_type_of(right_name));

    const keys = [_]Order{
        std.math.order(@backingInt(left.section), @backingInt(right.section)),
        std.math.order(@intFromBool(left.from), @intFromBool(right.from)),
        std.math.order(right.level, left.level),
        compare_natural(left_module, right_module, true),
        compare_natural(left_module, right_module, false),
        std.math.order(alias_rank(left), alias_rank(right)),
        std.math.order(left_type, right_type),
        compare_natural(left_name, right_name, true),
        compare_natural(left_name, right_name, false),
        std.mem.order(u8, left.as_name.text(source), right.as_name.text(source)),
    };

    for (keys) |key| {
        if (key != .eq) return key;
    }

    return .eq;
}

fn alias_rank(row: Row) u8 {
    assert(row.from or row.level == 0);
    assert(row.from or row.name.length == 0);

    if (row.from) {
        if (row.as_name.length > 0) return 1;
    }

    return 0;
}

fn member_type_of(name: []const u8) MemberType {
    assert(name.len <= std.math.maxInt(u32));

    var has_upper = false;
    var has_lower = false;

    for (name) |byte| {
        if (std.ascii.isUpper(byte)) has_upper = true;
        if (std.ascii.isLower(byte)) has_lower = true;
    }

    if (name.len == 0) assert(!has_upper);
    if (name.len == 0) assert(!has_lower);

    if (name.len > 1) {
        if (has_upper) {
            if (!has_lower) return .constant;
        }
    }

    if (name.len > 0) {
        if (std.ascii.isUpper(name[0])) return .class;
    }

    return .variable;
}

fn compare_natural(left: []const u8, right: []const u8, ignore_case: bool) Order {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    var left_at: usize = 0;
    var right_at: usize = 0;

    for (0..@max(left.len, right.len) + 1) |_| {
        assert(left_at <= left.len);
        assert(right_at <= right.len);

        const exhausted = left_at >= left.len or right_at >= right.len;
        if (exhausted) return std.math.order(left.len -| left_at, right.len -| right_at);

        const one = left[left_at];
        const two = right[right_at];
        const digits = std.ascii.isDigit(one) and std.ascii.isDigit(two);

        if (digits) {
            const left_run = digit_run(left, left_at);
            const right_run = digit_run(right, right_at);
            const held = compare_digit_runs(left[left_at..left_run], right[right_at..right_run]);
            if (held != .eq) return held;

            left_at = left_run;
            right_at = right_run;

            continue;
        }

        const held = if (ignore_case)
            std.math.order(std.ascii.toLower(one), std.ascii.toLower(two))
        else
            std.math.order(one, two);

        if (held != .eq) return held;

        left_at += 1;
        right_at += 1;
    }

    unreachable;
}

fn digit_run(bytes: []const u8, start: usize) usize {
    assert(start < bytes.len);

    var end = start;

    while (end < bytes.len) : (end += 1) {
        assert(end >= start);

        if (!std.ascii.isDigit(bytes[end])) break;
    }

    assert(end > start);

    return end;
}

fn compare_digit_runs(left: []const u8, right: []const u8) Order {
    assert(left.len > 0);
    assert(right.len > 0);

    const zero_led = left[0] == '0' or right[0] == '0';
    if (zero_led) return std.mem.order(u8, left, right);

    const by_length = std.math.order(left.len, right.len);
    if (by_length != .eq) return by_length;
    return std.mem.order(u8, left, right);
}

fn deduplicated(source: []const u8, rows: []Row) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(rows.len <= std.math.maxInt(u32));

    var kept: u32 = 0;

    for (0..rows.len) |index| {
        if (kept > 0) {
            if (same_row(source, rows[kept - 1], rows[index])) {
                rows[kept - 1].trailing_comma = rows[kept - 1].trailing_comma or
                    rows[index].trailing_comma;

                continue;
            }
        }

        rows[kept] = rows[index];
        kept += 1;
    }

    assert(kept <= rows.len);
    if (rows.len > 0) assert(kept > 0);

    return kept;
}

fn same_row(source: []const u8, left: Row, right: Row) bool {
    assert(left.module.end() <= source.len);
    assert(right.module.end() <= source.len);

    if (left.from != right.from) return false;
    if (left.level != right.level) return false;
    if (!std.mem.eql(u8, left.module.text(source), right.module.text(source))) return false;
    if (!std.mem.eql(u8, left.name.text(source), right.name.text(source))) return false;
    return std.mem.eql(u8, left.as_name.text(source), right.as_name.text(source));
}

fn render_rows(
    source: []const u8,
    rows: []const Row,
    style: Style,
    line_width: u32,
    out: *Buffer,
) Buffer.CapacityError!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(rows.len <= std.math.maxInt(u32));
    assert(style.line_ending.bytes().len > 0);

    const ending = style.line_ending.bytes();
    var section: ?Section = null;
    var index: usize = 0;

    assert(ending.len > 0);
    assert(line_width > 0);

    for (0..rows.len) |_| {
        if (index == rows.len) break;

        const row = rows[index];

        if (section) |held| {
            if (held != row.section) try out.push(ending);
        }

        section = row.section;

        if (!row.from) {
            try render_plain(source, row, ending, out);
            index += 1;

            continue;
        }

        const end = group_end(source, rows, index);

        try render_group(source, rows[index..end], style, line_width, out);
        index = end;
    }

    assert(index == rows.len);
}

fn group_end(source: []const u8, rows: []const Row, start: usize) usize {
    assert(start < rows.len);
    assert(source.len <= std.math.maxInt(u32));

    const head = rows[start];
    var end = start + 1;

    while (end < rows.len) : (end += 1) {
        const row = rows[end];
        if (!row.from) break;
        if (row.level != head.level) break;
        if (!std.mem.eql(u8, row.module.text(source), head.module.text(source))) break;
    }

    assert(end > start);

    return end;
}

fn render_plain(
    source: []const u8,
    row: Row,
    ending: []const u8,
    out: *Buffer,
) Buffer.CapacityError!void {
    assert(!row.from);
    assert(ending.len > 0);
    assert(source.len <= std.math.maxInt(u32));

    try out.push("import ");
    try out.push(row.module.text(source));

    if (row.as_name.length > 0) {
        try out.push(" as ");
        try out.push(row.as_name.text(source));
    }

    try out.push(ending);
}

fn render_group(
    source: []const u8,
    rows: []const Row,
    style: Style,
    line_width: u32,
    out: *Buffer,
) Buffer.CapacityError!void {
    assert(rows.len > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(line_width < std.math.maxInt(u32));
    assert(style.line_ending.bytes().len > 0);

    var plain: usize = 0;

    while (plain < rows.len) : (plain += 1) {
        if (rows[plain].as_name.length > 0) break;
    }

    assert(plain <= rows.len);

    if (plain > 0) try render_names(source, rows[0..plain], style, line_width, out);

    for (rows[plain..]) |*row| {
        try render_names(source, row[0..1], style, line_width, out);
    }
}

fn render_names(
    source: []const u8,
    rows: []const Row,
    style: Style,
    line_width: u32,
    out: *Buffer,
) Buffer.CapacityError!void {
    assert(rows.len > 0);
    assert(line_width > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(style.line_ending.bytes().len > 0);

    var exploded = false;

    for (rows) |row| {
        if (row.trailing_comma) exploded = true;
    }

    if (!exploded) {
        if (flat_width(rows) <= line_width) return render_flat(source, rows, style, out);
    }

    try render_wrapped(source, rows, style, out);
}

fn flat_width(rows: []const Row) u32 {
    assert(rows.len > 0);

    const head = rows[0];
    var found: u32 = @as(u32, "from  import ".len) + head.level + head.module.length;

    for (rows, 0..) |row, index| {
        found += name_width(row) + @as(u32, if (index > 0) 2 else 0);
    }

    assert(found >= "from  import ".len);

    return found;
}

fn name_width(row: Row) u32 {
    assert(row.from);
    assert(row.name.length > 0);

    if (row.as_name.length == 0) return row.name.length;
    const width = row.name.length + @as(u32, " as ".len) + row.as_name.length;

    assert(width > row.name.length);

    return width;
}

fn write_head(source: []const u8, row: Row, out: *Buffer) Buffer.CapacityError!void {
    assert(row.from);
    assert(row.module.end() <= source.len);

    try out.push("from ");

    for (0..row.level) |_| {
        try out.push_byte('.');
    }

    try out.push(row.module.text(source));
    try out.push(" import ");
}

fn write_name(source: []const u8, row: Row, out: *Buffer) Buffer.CapacityError!void {
    assert(row.from);
    assert(row.name.end() <= source.len);

    try out.push(row.name.text(source));

    if (row.as_name.length == 0) return;

    try out.push(" as ");
    try out.push(row.as_name.text(source));
}

fn render_flat(
    source: []const u8,
    rows: []const Row,
    style: Style,
    out: *Buffer,
) Buffer.CapacityError!void {
    assert(rows.len > 0);
    assert(rows[0].from);
    assert(source.len <= std.math.maxInt(u32));
    assert(style.line_ending.bytes().len > 0);

    try write_head(source, rows[0], out);

    for (rows, 0..) |row, index| {
        if (index > 0) try out.push(", ");

        try write_name(source, row, out);
    }

    try out.push(style.line_ending.bytes());
}

fn render_wrapped(
    source: []const u8,
    rows: []const Row,
    style: Style,
    out: *Buffer,
) Buffer.CapacityError!void {
    assert(rows.len > 0);
    assert(rows[0].from);
    assert(source.len <= std.math.maxInt(u32));
    assert(style.line_ending.bytes().len > 0);

    const ending = style.line_ending.bytes();

    try write_head(source, rows[0], out);
    try out.push("(");
    try out.push(ending);

    for (rows) |row| {
        try write_indent(source, style, out);
        try write_name(source, row, out);
        try out.push(",");
        try out.push(ending);
    }

    try out.push(")");
    try out.push(ending);
}

fn write_indent(source: []const u8, style: Style, out: *Buffer) Buffer.CapacityError!void {
    assert(style.indent.end() <= source.len);

    if (style.indent.length > 0) return out.push(style.indent.text(source));
    if (style.indent_tabs) return out.push_byte('\t');

    for (0..style.indent_width) |_| {
        try out.push_byte(' ');
    }
}
