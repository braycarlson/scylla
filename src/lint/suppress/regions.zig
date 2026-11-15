const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const CodeSet = @import("../rule/code_set.zig");
const LineIndex = @import("../../text/line_index.zig").LineIndex;
const Registry = @import("../rule/registry.zig");
const Rule = @import("../rule/rule.zig");
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("../../syntax/token.zig");
const Tokens = @import("../../syntax/tokens.zig");
const ascii_whitespace = @import("../../text/scan.zig").ascii_whitespace;
const lex = @import("../../syntax/lex.zig").lex;
const rule_count_max = CodeSet.rule_count_max;

dropped: u32,
entries: ArrayType(Suppression),
file: CodeSet,

const Regions = @This();
pub const CapacityError = error{TargetExhausted};

pub const Claim = struct {
    line: u32,
    rule_index: u32,
};

pub const Markers = struct {
    annotation: []const u8,
    close: []const u8,
    disable: []const u8,
    enable: []const u8,
    file: []const u8,
    line: []const u8,
    open: []const u8,
};

pub const Suppression = struct {
    codes: CodeSet,
    first: u32,
    kind: Kind,
    line: u32,
    marker: Span,
    payload: Span,
    span: Span,
    trailing: bool,
    unclosed: bool,
    unknown: bool,
    used: CodeSet,
    wildcard: bool,

    pub const Kind = enum {
        disable,
        enable,
        file,
        line,
    };
};

pub const Unused = struct {
    kept: CodeSet,
    marker: Span,
    payload: Span,
    reason: Reason,
    span: Span,
    trailing: bool,

    pub const Reason = enum {
        closes,
        dead,
        unknown,
    };

    pub fn removal(unused: *const Unused, index: *const LineIndex, source: []const u8) Span {
        assert(unused.span.end() <= source.len);

        const line_at = index.line_of(unused.span.offset);
        const line = index.line_span(line_at, source);

        if (!unused.trailing) return index.line_span_terminated(line_at, source);

        assert(line.offset <= unused.span.offset);

        const before = source[line.offset..unused.span.offset];
        const kept = std.mem.trimEnd(u8, before, ascii_whitespace);
        const start = line.offset + @as(u32, @intCast(kept.len));

        return Span.between(start, line.end());
    }
};

const Codes = struct {
    offset: u32,
    remaining: u32,
    text: []const u8,

    fn next(codes: *Codes) ?Span {
        assert(codes.offset <= codes.text.len);
        assert(codes.text.len <= std.math.maxInt(u32));
        assert(codes.remaining <= codes.text.len);

        const length: u32 = @intCast(codes.text.len);

        if (codes.remaining == 0) return null;

        for (0..length) |_| {
            if (codes.offset >= length) break;

            if (!std.ascii.isAlphanumeric(codes.text[codes.offset])) {
                codes.offset += 1;

                continue;
            }

            const start = codes.offset;
            const end = code_end(codes.text, start);

            assert(end > start);

            codes.offset = end;
            codes.remaining -= 1;

            return Span.between(start, end);
        }

        assert(codes.offset == length);

        return null;
    }
};

const Parsed = struct {
    codes: u128,
    kind: Suppression.Kind,
    marker: Span,
    payload: Span,
    unclosed: bool,
    unknown: bool,
    wildcard: bool,
};

const Coded = struct {
    codes: u128,
    unknown: bool,
    wildcard: bool,
};

const Listed = struct {
    width: u32,
    length: u32,
    closed: bool,
};

const MarkerKind = struct {
    marker: []const u8,
    kind: Suppression.Kind,
};

const annotation_count_max: u32 = 32;
const codes_all: u128 = std.math.maxInt(u128);

pub fn init(gpa: std.mem.Allocator, directive_count_max: u32) std.mem.Allocator.Error!Regions {
    assert(directive_count_max > 0);

    const entries = try ArrayType(Suppression).init(gpa, directive_count_max);

    assert(entries.count() == 0);
    assert(entries.capacity() == directive_count_max);

    return .{ .dropped = 0, .entries = entries, .file = .empty };
}

pub fn deinit(regions: *Regions, gpa: std.mem.Allocator) void {
    assert(regions.entries.count() <= regions.entries.capacity());

    regions.entries.deinit(gpa);
    regions.* = undefined;
}

pub fn scan(
    regions: *Regions,
    rules: *const Registry,
    index: *const LineIndex,
    markers: *const Markers,
    source: []const u8,
    comments: []const Span,
) void {
    assert(rules.count() <= rule_count_max);
    assert(index.count() > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(comments.len <= std.math.maxInt(u32));

    regions.scan_with(source, comments, index, markers, rules, Registry.index_of);
}

fn scan_with(
    regions: *Regions,
    source: []const u8,
    comments: []const Span,
    index: *const LineIndex,
    markers: *const Markers,
    context: anytype,
    comptime code_of: fn (@TypeOf(context), []const u8) ?u32,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(index.count() > 0);
    assert(comments.len <= std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(context)) == .pointer or @TypeOf(context) == void);

    regions.clear();

    for (comments) |comment| {
        assert(comment.end() <= source.len);

        const line = index.line_of(comment.offset);
        const own_line = leading(source, index, line, comment.offset);
        const text = comment.text(source);
        const parsed = directive_of(text, markers, context, code_of) orelse continue;

        if (parsed.kind == .file) regions.file = regions.file.union_with(.of_bits(parsed.codes));

        const annotated = parsed.kind == .line and own_line;

        const target = if (annotated)
            annotation_skipped(source, index, markers.annotation, line + 1)
        else
            line;

        if (regions.entries.full()) {
            regions.dropped += 1;

            continue;
        }

        regions.entries.push(.{
            .codes = .of_bits(parsed.codes),
            .first = @min(target, line + 1),
            .kind = parsed.kind,
            .line = target,
            .marker = parsed.marker.shifted(comment.offset),
            .payload = parsed.payload.shifted(comment.offset),
            .span = comment,
            .trailing = !own_line,
            .unclosed = parsed.unclosed,
            .unknown = parsed.unknown,
            .used = .empty,
            .wildcard = parsed.wildcard,
        });
    }

    assert(regions.entries.count() + regions.dropped <= comments.len);
}

fn at(regions: *const Regions, index: u32) Suppression {
    assert(index < regions.entries.count());

    return regions.entries.get(index);
}

pub fn capacity(regions: *const Regions) u32 {
    const held = regions.entries.capacity();

    assert(held > 0);

    return held;
}

pub fn claim(regions: *Regions, claimed: Claim) bool {
    assert(claimed.rule_index < rule_count_max);
    assert(regions.entries.count() <= regions.entries.capacity());

    if (regions.file.contains(claimed.rule_index)) {
        regions.mark(claimed.rule_index);

        return true;
    }

    const entries = regions.entries.slice();

    for (entries, 0..) |entry, entry_index| {
        if (!entry.codes.contains(claimed.rule_index)) continue;

        if (regions_line_covers(&entry, claimed.line)) {
            entries[entry_index].used.insert(claimed.rule_index);

            return true;
        }

        if (entry.kind != .disable) continue;
        if (entry.line > claimed.line) continue;

        const reenabled = regions.reopened(@intCast(entry_index), claimed);
        if (reenabled) continue;

        entries[entry_index].used.insert(claimed.rule_index);

        return true;
    }

    return false;
}

fn clear(regions: *Regions) void {
    regions.dropped = 0;

    regions.entries.clear();
    regions.file = .empty;

    assert(regions.count() == 0);
}

pub fn count(regions: *const Regions) u32 {
    const held = regions.entries.count();

    assert(held <= regions.entries.capacity());

    return held;
}

pub fn dropped_count(regions: *const Regions) u32 {
    assert(regions.entries.count() <= regions.entries.capacity());
    if (regions.dropped > 0) assert(regions.entries.full());

    return regions.dropped;
}

fn unclosed_at(regions: *const Regions, index: u32) bool {
    if (index >= regions.entries.count()) return false;

    const entries = regions.entries.const_slice();
    const entry = entries[index];
    if (entry.kind != .disable) return false;

    for (entries[index + 1 ..]) |other| {
        if (other.kind != .enable) continue;
        if (!other.codes.intersect_with(entry.codes).is_empty()) return false;
    }

    assert(entry.kind == .disable);

    return true;
}

pub fn unused_at(regions: *const Regions, index: u32, enabled: CodeSet) ?Unused {
    assert(index < regions.entries.count());

    const entry = regions.entries.get(index);

    var whole: Unused = .{
        .kept = .empty,
        .marker = entry.marker,
        .payload = entry.payload,
        .reason = .dead,
        .span = entry.span,
        .trailing = entry.trailing,
    };

    if (entry.unknown) {
        whole.reason = .unknown;

        return whole;
    }

    if (entry.kind == .enable) {
        if (regions.opened(index)) return null;

        whole.reason = .closes;

        return whole;
    }

    if (entry.wildcard) {
        if (!entry.used.is_empty()) return null;
        return whole;
    }

    const dead = entry.codes.intersect_with(enabled).difference_with(entry.used);
    if (dead.is_empty()) return null;

    whole.kept = entry.codes.difference_with(dead);

    assert(whole.kept.intersect_with(dead).is_empty());

    return whole;
}

fn regions_line_covers(entry: *const Suppression, line: u32) bool {
    if (entry.kind != .line) return false;

    assert(entry.first <= entry.line);
    if (entry.first > line) return false;
    return line <= entry.line;
}

fn mark(regions: *Regions, rule_index: u32) void {
    assert(rule_index < rule_count_max);

    for (regions.entries.slice()) |*entry| {
        if (entry.kind != .file) continue;

        if (entry.codes.contains(rule_index)) entry.used.insert(rule_index);
    }
}

fn opened(regions: *const Regions, index: u32) bool {
    assert(index < regions.entries.count());

    const entries = regions.entries.const_slice();
    const codes = entries[index].codes;

    for (entries[0..index]) |entry| {
        if (entry.kind != .disable) continue;
        if (!entry.codes.intersect_with(codes).is_empty()) return true;
    }

    return false;
}

fn reopened(regions: *const Regions, start: u32, claimed: Claim) bool {
    assert(start < regions.entries.count());
    assert(claimed.rule_index < rule_count_max);

    const entries = regions.entries.const_slice();
    const start_line = entries[start].line;

    for (entries[start + 1 ..]) |entry| {
        if (entry.kind != .enable) continue;
        if (entry.line <= start_line) continue;
        if (entry.line > claimed.line) continue;
        if (entry.codes.contains(claimed.rule_index)) return true;
    }

    return false;
}

pub fn comment_spans(
    target: *ArrayType(Span),
    markers: *const Markers,
    source: []const u8,
    tokens: []const Token,
) CapacityError!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(target.count() <= target.capacity());
    assert(tokens.len <= std.math.maxInt(u32));

    try comment_spans_of(Token, source, tokens, markers, target, {}, token_comment_span);
}

fn token_comment_span(context: void, token: Token) ?Span {
    _ = context;

    if (token.kind != .comment) return null;
    return token.span();
}

fn comment_spans_of(
    comptime T: type,
    source: []const u8,
    tokens: []const T,
    markers: *const Markers,
    out: *ArrayType(Span),
    context: anytype,
    comptime comment_span: fn (@TypeOf(context), T) ?Span,
) CapacityError!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(context)) == .pointer or @TypeOf(context) == void);

    const words = [_][]const u8{ markers.disable, markers.enable, markers.file, markers.line };

    for (tokens) |token| {
        const span = comment_span(context, token) orelse continue;

        assert(span.end() <= source.len);

        if (!comment_marked(span.text(source), &words)) continue;
        if (out.full()) return error.TargetExhausted;

        out.push(span);
    }

    assert(out.count() <= tokens.len);
}

fn comment_marked(text: []const u8, words: []const []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (marker_find(text, word) != null) return true;
    }

    return false;
}

fn codes_at(text: []const u8) Codes {
    assert(text.len <= std.math.maxInt(u32));

    return .{ .offset = 0, .remaining = @intCast(text.len), .text = text };
}

fn code_end(text: []const u8, start: u32) u32 {
    assert(start < text.len);
    assert(std.ascii.isAlphanumeric(text[start]));

    var offset = start;

    for (text[start..]) |byte| {
        if (!code_named(byte)) break;

        offset += 1;
    }

    for (start..offset) |_| {
        if (std.ascii.isAlphanumeric(text[offset - 1])) break;

        offset -= 1;
    }

    assert(offset > start);

    return offset;
}

fn code_named(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;

    return switch (byte) {
        '-', '.', '/', '_' => true,
        else => false,
    };
}

fn leading(source: []const u8, index: *const LineIndex, line: u32, offset: u32) bool {
    assert(offset <= source.len);
    assert(line < std.math.maxInt(u32));

    const start = index.line_span(line, source).offset;

    assert(start <= offset);

    const before = std.mem.trim(u8, source[start..offset], ascii_whitespace);
    return before.len == 0;
}

fn annotation_skipped(
    source: []const u8,
    index: *const LineIndex,
    prefix: []const u8,
    from: u32,
) u32 {
    assert(from > 0);
    assert(index.count() > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(prefix.len <= std.math.maxInt(u32));

    if (prefix.len == 0) return from;

    var line = from;

    for (0..annotation_count_max) |_| {
        if (line >= index.count()) return from;

        const text = index.line_span(line, source).text(source);
        const trimmed = std.mem.trimStart(u8, text, ascii_whitespace);
        if (!std.mem.startsWith(u8, trimmed, prefix)) return line;

        const walked = annotation_walked(source, index, line) orelse return from;

        assert(walked > line);

        line = walked;
    }

    return from;
}

fn annotation_walked(source: []const u8, index: *const LineIndex, line: u32) ?u32 {
    assert(line < index.count());
    assert(source.len <= std.math.maxInt(u32));

    var depth: i32 = 0;
    var walked = line;

    for (0..annotation_count_max) |_| {
        if (walked >= index.count()) return null;

        for (index.line_span(walked, source).text(source)) |byte| {
            switch (byte) {
                '[', '(' => depth += 1,
                ']', ')' => depth -= 1,
                else => {},
            }
        }

        walked += 1;

        if (depth <= 0) break;
    }

    assert(walked > line);

    return walked;
}

fn directive_of(
    text: []const u8,
    markers: *const Markers,
    context: anytype,
    comptime code_of: fn (@TypeOf(context), []const u8) ?u32,
) ?Parsed {
    assert(text.len <= std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(context)) == .pointer or @TypeOf(context) == void);

    const body = reason_strip(text);

    assert(body.len <= text.len);

    const kinds = [_]MarkerKind{
        .{ .marker = markers.file, .kind = .file },
        .{ .marker = markers.disable, .kind = .disable },
        .{ .marker = markers.enable, .kind = .enable },
        .{ .marker = markers.line, .kind = .line },
    };

    for (kinds) |entry| {
        const start = marker_find(body, entry.marker) orelse continue;

        assert(start + entry.marker.len <= body.len);

        return directive_parsed(body, markers, &entry, start, context, code_of);
    }

    return null;
}

fn directive_parsed(
    body: []const u8,
    markers: *const Markers,
    entry: *const MarkerKind,
    start: u32,
    context: anytype,
    comptime code_of: fn (@TypeOf(context), []const u8) ?u32,
) Parsed {
    assert(entry.marker.len > 0);
    assert(start + entry.marker.len <= body.len);
    comptime assert(@typeInfo(@TypeOf(context)) == .pointer or @TypeOf(context) == void);

    const word: u32 = start + @as(u32, @intCast(entry.marker.len));
    var open = word;

    for (body[word..]) |byte| {
        if (byte != ' ') break;

        open += 1;
    }

    const listed = listed_of(body[open..], markers.open, markers.close) orelse return .{
        .codes = codes_all,
        .kind = entry.kind,
        .marker = Span.between(start, word),
        .payload = .{ .offset = word, .length = 0 },
        .unclosed = false,
        .unknown = false,
        .wildcard = true,
    };

    const from = open + listed.width;
    const list = body[from..][0..listed.length];
    const coded = codes_of(list, context, code_of);
    const close: u32 = @intCast(markers.close.len);
    const end: u32 = if (listed.closed) from + listed.length + close else @intCast(body.len);
    const payload = std.mem.trimEnd(u8, list, ascii_whitespace);

    assert(end <= body.len);

    return .{
        .codes = coded.codes,
        .kind = entry.kind,
        .marker = Span.between(start, end),
        .payload = .{ .offset = from, .length = @intCast(payload.len) },
        .unclosed = !listed.closed,
        .unknown = coded.unknown,
        .wildcard = coded.wildcard,
    };
}

fn listed_of(rest: []const u8, open: []const u8, close: []const u8) ?Listed {
    assert(rest.len <= std.math.maxInt(u32));
    assert(open.len <= std.math.maxInt(u32));
    assert(close.len <= std.math.maxInt(u32));

    if (open.len > 0) {
        if (!std.mem.startsWith(u8, rest, open)) return null;
    }

    const width: u32 = @intCast(open.len);
    const listed = rest[width..];
    if (close.len == 0) return .{ .width = width, .length = @intCast(listed.len), .closed = true };

    if (marker_find(listed, close)) |offset| {
        assert(offset + close.len <= listed.len);

        return .{ .width = width, .length = offset, .closed = true };
    }

    return .{ .width = width, .length = @intCast(listed.len), .closed = false };
}

fn codes_of(
    text: []const u8,
    context: anytype,
    comptime code_of: fn (@TypeOf(context), []const u8) ?u32,
) Coded {
    assert(text.len <= std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(context)) == .pointer or @TypeOf(context) == void);

    if (std.mem.findScalar(u8, text, '*') != null) {
        return .{ .codes = codes_all, .unknown = false, .wildcard = true };
    }

    var codes: u128 = 0;
    var found = false;
    var unknown = false;
    var iterator = codes_at(text);

    for (0..text.len + 1) |_| {
        const span = iterator.next() orelse break;

        const value = code_of(context, span.text(text)) orelse {
            unknown = true;

            continue;
        };

        if (value >= rule_count_max) {
            unknown = true;

            continue;
        }

        codes |= @as(u128, 1) << @intCast(value);
        found = true;
    }

    assert(iterator.offset == text.len);

    if (!found) {
        if (!unknown) return .{ .codes = codes_all, .unknown = false, .wildcard = true };
    }

    if (found) assert(codes != 0);

    return .{ .codes = codes, .unknown = unknown, .wildcard = false };
}

fn reason_strip(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    const offset = marker_find(text, " -- ") orelse return text;

    assert(offset < text.len);

    return text[0..offset];
}

fn marker_find(haystack: []const u8, needle: []const u8) ?u32 {
    assert(haystack.len <= std.math.maxInt(u32));

    if (needle.len == 0) return null;

    const offset = std.mem.find(u8, haystack, needle) orelse return null;

    assert(offset + needle.len <= haystack.len);

    return @intCast(offset);
}

const tigerstyle: Markers = .{
    .annotation = "#[",
    .close = "",
    .disable = "tigerstyle-disable:",
    .enable = "tigerstyle-enable:",
    .file = "tigerstyle-file-ignore:",
    .line = "tigerstyle-ignore:",
    .open = "",
};

const glue: Markers = .{
    .annotation = "",
    .close = ")",
    .disable = "glue: off",
    .enable = "glue: on",
    .file = "glue: ok-file",
    .line = "glue: ok",
    .open = "(",
};

const TestParsed = struct {
    kind: Suppression.Kind,
    codes: u128,
    unknown: bool,
};

const test_span_count_max: u32 = 16;

fn test_tigerstyle_code(context: void, code: []const u8) ?u32 {
    _ = context;

    if (code.len < 3) return null;
    if (!std.mem.eql(u8, code[0..2], "TS")) return null;
    return std.fmt.parseInt(u32, code[2..], 10) catch null;
}

fn test_glue_code(context: void, code: []const u8) ?u32 {
    _ = context;
    assert(code.len <= std.math.maxInt(u32));

    if (std.mem.eql(u8, code, "GL001")) return 1;
    if (std.mem.eql(u8, code, "glue/registration-args")) return 1;
    if (std.mem.eql(u8, code, "GL015")) return 15;
    if (std.mem.eql(u8, code, "glue/unregistered-name")) return 15;
    return null;
}

fn test_parsed_of(text: []const u8) !TestParsed {
    assert(text.len <= std.math.maxInt(u32));

    const parsed = directive_of(text, &tigerstyle, {}, test_tigerstyle_code) orelse {
        return error.TestUnexpectedResult;
    };

    return .{ .kind = parsed.kind, .codes = parsed.codes, .unknown = parsed.unknown };
}

fn test_glue_of(text: []const u8) !Parsed {
    assert(text.len <= std.math.maxInt(u32));

    const parsed = directive_of(text, &glue, {}, test_glue_code) orelse {
        return error.TestUnexpectedResult;
    };

    return parsed;
}

fn test_regions_of(
    source: []const u8,
    spans: []const Span,
    markers: *const Markers,
    comptime code_of: fn (void, []const u8) ?u32,
) !Regions {
    assert(spans.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;

    assert(source.len > 0);

    var index: LineIndex = try .init(gpa, 64);
    defer index.deinit(gpa);

    try index.build(source);

    var regions: Regions = try .init(gpa, 8);

    regions.scan_with(source, spans, &index, markers, {}, code_of);

    assert(regions.count() <= spans.len);

    return regions;
}

fn test_fenced_of(source: []const u8, open: []const u8, close: []const u8, spans: []Span) []Span {
    assert(open.len > 0);
    assert(close.len > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(spans.len <= std.math.maxInt(u32));

    var held: u32 = 0;
    var cursor: u32 = 0;

    for (0..spans.len) |_| {
        const start = marker_find(source[cursor..], open) orelse break;
        const offset = cursor + start;
        const end = marker_find(source[offset..], close) orelse break;
        const length: u32 = end + @as(u32, @intCast(close.len));

        spans[held] = .{ .offset = offset, .length = length };
        held += 1;
        cursor = offset + length;
    }

    return spans[0..held];
}

fn test_span(offset: u32, length: u32) Span {
    assert(offset < std.math.maxInt(u32));
    assert(length < std.math.maxInt(u32));

    return .{ .offset = offset, .length = length };
}

fn test_rule(code: []const u8, name: []const u8) Rule {
    assert(code.len > 0);
    assert(name.len > 0);

    return .{
        .citations = &.{},
        .code = code,
        .default_on = true,
        .description = "",
        .explanation = "",
        .fix_title = "",
        .fixable = .never,
        .group = .stable,
        .name = name,
        .severity = .warning,
        .summary = "",
        .url = "",
    };
}

test Regions {
    const gpa = std.testing.allocator;
    const source = "let x = 1;\n// tigerstyle-ignore: TS002\nlet y = 2;\n";
    const rules = [_]Rule{ test_rule("TS001", "first"), test_rule("TS002", "second") };
    var registry: Registry = try .init(gpa, rules.len);
    defer registry.deinit(gpa);

    for (&rules) |*item| registry.register(item);

    var index: LineIndex = try .init(gpa, 8);
    defer index.deinit(gpa);

    try index.build(source);

    var regions: Regions = try .init(gpa, 4);
    defer regions.deinit(gpa);

    regions.scan(&registry, &index, &tigerstyle, source, &.{test_span(11, 27)});

    try std.testing.expectEqual(@as(u32, 1), regions.count());
    try std.testing.expect(regions.claim(.{ .line = 2, .rule_index = 1 }));
    try std.testing.expect(!regions.claim(.{ .line = 2, .rule_index = 0 }));
    try std.testing.expect(regions.unused_at(0, .with_all(rules.len)) == null);
}

test "a directive lists its codes" {
    const both: u128 = (1 << 2) | (1 << 3);

    try std.testing.expectEqual(
        TestParsed{ .kind = .line, .codes = both, .unknown = false },
        try test_parsed_of("// tigerstyle-ignore: TS002, TS003"),
    );

    try std.testing.expectEqual(
        TestParsed{ .kind = .line, .codes = codes_all, .unknown = false },
        try test_parsed_of("# tigerstyle-ignore: *"),
    );

    try std.testing.expectEqual(
        TestParsed{ .kind = .line, .codes = codes_all, .unknown = false },
        try test_parsed_of("# tigerstyle-ignore:"),
    );

    try std.testing.expect(directive_of("# a note", &tigerstyle, {}, test_tigerstyle_code) == null);
}

test "a directive drops its reason" {
    try std.testing.expectEqual(
        TestParsed{ .kind = .line, .codes = 1 << 2, .unknown = false },
        try test_parsed_of("// tigerstyle-ignore: TS002 -- the vendor writes it this way"),
    );
}

test "a directive spans its payload" {
    const text = "// tigerstyle-ignore: TS002, TS003 -- a reason";
    const parsed = directive_of(text, &tigerstyle, {}, test_tigerstyle_code).?;

    try std.testing.expectEqual(@as(u32, 22), parsed.payload.offset);
    try std.testing.expectEqual(@as(u32, 12), parsed.payload.length);
    try std.testing.expect(!parsed.wildcard);
}

test "a region directive reads its kind" {
    try std.testing.expectEqual(
        TestParsed{ .kind = .disable, .codes = 1 << 12, .unknown = false },
        try test_parsed_of("// tigerstyle-disable: TS012"),
    );

    try std.testing.expectEqual(
        TestParsed{ .kind = .enable, .codes = 1 << 12, .unknown = false },
        try test_parsed_of("// tigerstyle-enable: TS012"),
    );

    try std.testing.expectEqual(
        TestParsed{ .kind = .file, .codes = 1 << 12, .unknown = false },
        try test_parsed_of("// tigerstyle-file-ignore: TS012"),
    );
}

test "an unknown code is recorded" {
    try std.testing.expectEqual(
        TestParsed{ .kind = .line, .codes = 0, .unknown = true },
        try test_parsed_of("// tigerstyle-ignore: TS999"),
    );
}

test "a directive on its own line claims the line below it" {
    const source = "// tigerstyle-ignore: TS002\nlet x = 1;\nlet y = 2;\n";
    const spans = [_]Span{test_span(0, 27)};
    var regions = try test_regions_of(source, &spans, &tigerstyle, test_tigerstyle_code);
    defer regions.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), regions.count());
    try std.testing.expect(regions.claim(.{ .line = 1, .rule_index = 2 }));
    try std.testing.expect(!regions.claim(.{ .line = 2, .rule_index = 2 }));
    try std.testing.expect(!regions.claim(.{ .line = 1, .rule_index = 3 }));
    try std.testing.expect(regions.unused_at(0, .of_bits(codes_all)) == null);
}

test "a trailing directive claims the line it sits on" {
    const source = "let x = 1; // tigerstyle-ignore: TS002\nlet y = 2;\n";
    const spans = [_]Span{test_span(11, 27)};
    var regions = try test_regions_of(source, &spans, &tigerstyle, test_tigerstyle_code);
    defer regions.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), regions.count());
    try std.testing.expect(regions.claim(.{ .line = 0, .rule_index = 2 }));
    try std.testing.expect(!regions.claim(.{ .line = 1, .rule_index = 2 }));
}

test "a template comment the lexer never tokenised suppresses" {
    const source = "{# tigerstyle-ignore: TS002 #}\n{% extends 'base.html' %}\n" ++
        "<p>{# tigerstyle-ignore: TS003 #}</p>\n";

    var buffer: [test_span_count_max]Span = undefined;
    const spans = test_fenced_of(source, "{#", "#}", &buffer);
    var regions = try test_regions_of(source, spans, &tigerstyle, test_tigerstyle_code);
    defer regions.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(@as(u32, 2), regions.count());
    try std.testing.expect(regions.claim(.{ .line = 1, .rule_index = 2 }));
    try std.testing.expect(regions.claim(.{ .line = 2, .rule_index = 3 }));
    try std.testing.expect(!regions.claim(.{ .line = 3, .rule_index = 3 }));
}

test "a file directive scanned from a span claims every line" {
    const source = "// tigerstyle-file-ignore: TS002\nlet x = 1;\nlet y = 2;\n";
    const spans = [_]Span{test_span(0, 32)};
    var regions = try test_regions_of(source, &spans, &tigerstyle, test_tigerstyle_code);
    defer regions.deinit(std.testing.allocator);

    try std.testing.expect(regions.claim(.{ .line = 0, .rule_index = 2 }));
    try std.testing.expect(regions.claim(.{ .line = 2, .rule_index = 2 }));
    try std.testing.expect(!regions.claim(.{ .line = 2, .rule_index = 3 }));
}

test "a scan forgets the regions before it" {
    const source = "// tigerstyle-ignore: TS002\nlet x = 1;\n";
    const spans = [_]Span{test_span(0, 27)};
    var regions = try test_regions_of(source, &spans, &tigerstyle, test_tigerstyle_code);
    defer regions.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), regions.count());

    regions.clear();

    try std.testing.expectEqual(@as(u32, 0), regions.count());
    try std.testing.expect(!regions.claim(.{ .line = 1, .rule_index = 2 }));
}

test "a file directive nothing claims reads dead" {
    const source = "// tigerstyle-file-ignore: TS002\nlet x = 1;\n";
    const spans = [_]Span{test_span(0, 32)};
    var regions = try test_regions_of(source, &spans, &tigerstyle, test_tigerstyle_code);
    defer regions.deinit(std.testing.allocator);

    try std.testing.expect(regions.unused_at(0, .of_bits(codes_all)) != null);
    try std.testing.expect(regions.claim(.{ .line = 1, .rule_index = 2 }));
    try std.testing.expect(regions.unused_at(0, .of_bits(codes_all)) == null);
}

test "an unused directive scanned from a span reads dead" {
    const source = "// tigerstyle-ignore: TS002\nlet x = 1;\n";
    const spans = [_]Span{test_span(0, 27)};
    var regions = try test_regions_of(source, &spans, &tigerstyle, test_tigerstyle_code);
    defer regions.deinit(std.testing.allocator);

    const found = regions.unused_at(0, .of_bits(codes_all)).?;

    try std.testing.expectEqual(Unused.Reason.dead, found.reason);
    try std.testing.expectEqual(test_span(0, 27), found.span);
    try std.testing.expect(!found.trailing);
    try std.testing.expectEqualStrings("TS002", found.payload.text(source));
}

test "an unused directive is removed with its line or its trailing gap" {
    const gpa = std.testing.allocator;
    const source = "// tigerstyle-ignore: TS002\nlet x = 1;  // tigerstyle-ignore: TS003\n";
    const spans = [_]Span{ test_span(0, 27), test_span(40, 27) };
    var regions = try test_regions_of(source, &spans, &tigerstyle, test_tigerstyle_code);
    defer regions.deinit(gpa);

    var index: LineIndex = try .init(gpa, 8);
    defer index.deinit(gpa);

    try index.build(source);

    const own = regions.unused_at(0, .of_bits(codes_all)).?;
    const trailing = regions.unused_at(1, .of_bits(codes_all)).?;

    try std.testing.expectEqual(test_span(0, 28), own.removal(&index, source));
    try std.testing.expectEqual(test_span(38, 29), trailing.removal(&index, source));
}

test "a code token runs through a rule name" {
    const parsed = try test_glue_of("{# glue: ok(glue/unregistered-name) #}");

    try std.testing.expectEqual(Suppression.Kind.line, parsed.kind);
    try std.testing.expectEqual(@as(u128, 1 << 15), parsed.codes);
    try std.testing.expect(!parsed.unknown);
}

test "a closing delimiter ends the list and the prose after it is not a code" {
    const parsed = try test_glue_of("{# glue: ok(GL001) the api is legacy #}");

    try std.testing.expectEqual(@as(u128, 1 << 1), parsed.codes);
    try std.testing.expect(!parsed.unknown);
}

test "a close that never arrives reads the whole list" {
    const parsed = try test_glue_of("{# glue: ok(GL001, GL015 #}");

    try std.testing.expectEqual(@as(u128, (1 << 1) | (1 << 15)), parsed.codes);
    try std.testing.expect(!parsed.unknown);
}

test "a file marker wins over the line marker it contains" {
    const parsed = try test_glue_of("{# glue: ok-file(GL001) #}");

    try std.testing.expectEqual(Suppression.Kind.file, parsed.kind);
    try std.testing.expectEqual(@as(u128, 1 << 1), parsed.codes);
}

test "a marker after prose still parses" {
    const parsed = try test_glue_of("{# TODO drop this glue: ok(GL015) #}");

    try std.testing.expectEqual(@as(u128, 1 << 15), parsed.codes);
    try std.testing.expect(!parsed.unknown);
}

test "a close before the marker is not the end of the list" {
    const parsed = try test_glue_of("{# see build() glue: ok(GL001) why #}");

    try std.testing.expectEqual(@as(u128, 1 << 1), parsed.codes);
    try std.testing.expect(!parsed.unknown);
}

test "a trailing separator is not part of the code" {
    try std.testing.expectEqual(
        TestParsed{ .kind = .line, .codes = 1 << 2, .unknown = false },
        try test_parsed_of("// tigerstyle-ignore: TS002."),
    );

    try std.testing.expectEqual(
        TestParsed{ .kind = .line, .codes = 1 << 2, .unknown = false },
        try test_parsed_of("// tigerstyle-ignore: TS002-"),
    );
}

test "a marker spans its own text and no more" {
    const text = "{# glue: ok(GL001) #}";
    const parsed = try test_glue_of(text);

    try std.testing.expectEqualStrings("glue: ok(GL001)", parsed.marker.text(text));
    try std.testing.expectEqualStrings("GL001", parsed.payload.text(text));
    try std.testing.expect(!parsed.unclosed);
}

test "a marker that opens no list spans the word alone" {
    const text = "{# glue: ok #}";
    const parsed = try test_glue_of(text);

    try std.testing.expectEqualStrings("glue: ok", parsed.marker.text(text));
    try std.testing.expectEqual(codes_all, parsed.codes);
    try std.testing.expect(parsed.wildcard);
    try std.testing.expect(!parsed.unknown);
}

test "prose where a list would open is not a code" {
    const parsed = try test_glue_of("{# glue: ok the api is legacy #}");

    try std.testing.expect(parsed.wildcard);
    try std.testing.expect(!parsed.unknown);
}

test "a file marker that opens no list is a blanket" {
    const parsed = try test_glue_of("{# glue: ok-file #}");

    try std.testing.expectEqual(Suppression.Kind.file, parsed.kind);
    try std.testing.expect(parsed.wildcard);
}

test "a list that never closes reads unclosed" {
    const parsed = try test_glue_of("{# glue: ok(GL001 #}");

    try std.testing.expect(parsed.unclosed);
    try std.testing.expectEqual(@as(u128, 1 << 1), parsed.codes);

    const closed = try test_glue_of("{# glue: ok(GL001) #}");

    try std.testing.expect(!closed.unclosed);
}

test "a list names the span of every code it holds" {
    const text = "GL001, glue/unregistered-name";
    var buffer: [test_span_count_max]Span = undefined;
    const spans = test_codes_of(text, &buffer);

    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("GL001", spans[0].text(text));
    try std.testing.expectEqualStrings("glue/unregistered-name", spans[1].text(text));
}

fn test_codes_of(text: []const u8, buffer: []Span) []Span {
    assert(buffer.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    var codes = codes_at(text);
    var found: u32 = 0;

    for (0..buffer.len) |_| {
        const span = codes.next() orelse break;

        buffer[found] = span;
        found += 1;
    }

    assert(found <= buffer.len);

    return buffer[0..found];
}

test "a disable no enable closes reads unclosed" {
    const source = "{# glue: off(GL001) #}\n<p>x</p>\n{# glue: on(GL015) #}\n";
    var buffer: [test_span_count_max]Span = undefined;
    const spans = test_fenced_of(source, "{#", "#}", &buffer);
    var regions = try test_regions_of(source, spans, &glue, test_glue_code);
    defer regions.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), regions.count());
    try std.testing.expect(regions.unclosed_at(0));
    try std.testing.expect(!regions.unclosed_at(1));
    try std.testing.expectEqual(Suppression.Kind.disable, regions.at(0).kind);
}

test "a disable an enable closes reads closed" {
    const source = "{# glue: off(GL001) #}\n<p>x</p>\n{# glue: on(GL001) #}\n";
    var buffer: [test_span_count_max]Span = undefined;
    const spans = test_fenced_of(source, "{#", "#}", &buffer);
    var regions = try test_regions_of(source, spans, &glue, test_glue_code);
    defer regions.deinit(std.testing.allocator);

    try std.testing.expect(!regions.unclosed_at(0));
}

test "comment spans keeps the comments that carry a marker word" {
    const gpa = std.testing.allocator;
    const source = "// plain\nlet x = 1; // tool: ok(TS001)\n/* tool: off */\n";

    const markers: Markers = .{
        .annotation = "",
        .close = ")",
        .disable = "tool: off",
        .enable = "tool: on",
        .file = "tool: ok-file",
        .line = "tool: ok",
        .open = "(",
    };

    var tokens: Tokens = try .init(gpa, 32);
    defer tokens.deinit(gpa);

    try lex(.of(.rust), source, &tokens);

    var out: ArrayType(Span) = try .init(gpa, 4);
    defer out.deinit(gpa);

    try comment_spans(&out, &markers, source, tokens.slice());

    try std.testing.expectEqual(@as(u32, 2), out.count());
    try std.testing.expectEqualStrings("// tool: ok(TS001)", out.get(0).text(source));
    try std.testing.expectEqualStrings("/* tool: off */", out.get(1).text(source));

    var small: ArrayType(Span) = try .init(gpa, 1);
    defer small.deinit(gpa);

    try std.testing.expectError(
        error.TargetExhausted,
        comment_spans(&small, &markers, source, tokens.slice()),
    );

    try std.testing.expectEqual(@as(u32, 1), small.count());
}
