const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Span = @import("../../stdx/bounded/span.zig");
pub const Buffer = ArrayType(u8);
const FormatFields = ArrayType(FormatField);
pub const Origins = ArrayType(u32);
const PercentFields = ArrayType(PercentField);

const FieldName = union(enum) {
    auto,
    keyword: Span,
    positional: u32,
};

const FormatField = struct {
    conversion: u8,
    name: FieldName,
    span: Span,
    specification: Span,
};

pub const Number = union(enum) {
    complex,
    float,
    integer: u64,
    overflow,
};

pub const Outcome = union(enum) {
    complete,
    malformed: u32,
    overflow,
};

const PercentField = struct {
    conversion: u8,
    key: Span,
    precision_star: bool,
    span: Span,
    width_star: bool,
};

const Prefix = struct {
    bytes: bool = false,
    format: bool = false,
    raw: bool = false,
    template: bool = false,
    unicode: bool = false,
};

const Quote = struct {
    byte: u8,
    triple: bool,
};

pub const Shape = struct {
    content: Span,
    prefix: Prefix,
    quote: Quote,
};

const Escape = error{ Malformed, Truncated };
const Failure = error{ Malformed, Overflow, Truncated };

const FieldRead = struct {
    field: FormatField,
    next: u32,
};

pub const origin_escaped: u32 = std.math.maxInt(u32);
const field_count_max_default: u32 = 1 << 8;
const conversions = "diouxXeEfFgGcrsa%";
const octal_width_max: u32 = 3;
const prefix_length_max: u32 = 2;

pub fn shape_of(token: []const u8, offset: u32) ?Shape {
    assert(token.len <= std.math.maxInt(u32));
    assert(offset <= std.math.maxInt(u32) - token.len);

    const prefix_end = prefix_end_of(token) orelse return null;
    const quote = quote_of(token[prefix_end..]) orelse return null;
    const width: u32 = if (quote.triple) 3 else 1;
    const opening = prefix_end + width;

    assert(opening <= token.len);

    const closing: u32 = @intCast(token.len - width);
    if (closing < opening) return null;
    if (!std.mem.eql(u8, token[closing..], token[prefix_end..opening])) return null;

    return .{
        .content = .{ .offset = offset + opening, .length = closing - opening },
        .prefix = prefix_of(token),
        .quote = quote,
    };
}

pub fn prefix_of(token: []const u8) Prefix {
    assert(token.len <= std.math.maxInt(u32));

    var found: Prefix = .{};
    const end = prefix_end_of(token) orelse return found;

    assert(end <= prefix_length_max);

    for (token[0..end]) |byte| {
        const lower = std.ascii.toLower(byte);

        found.bytes = found.bytes or lower == 'b';
        found.format = found.format or lower == 'f';
        found.raw = found.raw or lower == 'r';
        found.template = found.template or lower == 't';
        found.unicode = found.unicode or lower == 'u';
    }

    if (found.template) assert(!found.bytes);
    if (found.unicode) assert(end == 1);

    return found;
}

pub fn decode(token: []const u8, out: *Buffer) Outcome {
    assert(token.len <= std.math.maxInt(u32));

    return decode_into(token, out, null);
}

pub fn decode_traced(token: []const u8, out: *Buffer, origins: *Origins) Outcome {
    assert(out.count() == origins.count());
    assert(token.len <= std.math.maxInt(u32));

    const outcome = decode_into(token, out, origins);

    if (outcome == .complete) assert(out.count() == origins.count());

    return outcome;
}

pub fn number_of(text: []const u8) Number {
    assert(text.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    if (std.ascii.toLower(text[text.len - 1]) == 'j') return .complex;

    const radix = radix_of(text);
    if (radix != 10) return integer_of(text[2..], radix);
    if (std.mem.findAny(u8, text, ".Ee") != null) return .float;
    return integer_of(text, 10);
}

fn percent_fields(template: []const u8, offset: u32, out: *PercentFields) Outcome {
    assert(template.len <= std.math.maxInt(u32));
    assert(offset <= std.math.maxInt(u32) - template.len);

    var index: u32 = 0;

    while (index < template.len) {
        if (template[index] != '%') {
            index += 1;

            continue;
        }

        if (byte_is(template, index + 1, '%')) {
            index += 2;

            continue;
        }

        index = percent_field(template, index, offset, out) catch |err| switch (err) {
            error.Malformed => return .{ .malformed = offset + index },
            error.Truncated => return .overflow,
        };
    }

    assert(index == template.len);

    return .complete;
}

fn format_fields(template: []const u8, offset: u32, out: *FormatFields) Outcome {
    assert(template.len <= std.math.maxInt(u32));
    assert(offset <= std.math.maxInt(u32) - template.len);

    var index: u32 = 0;

    while (index < template.len) {
        const byte = template[index];

        if (byte == '}') {
            if (!byte_is(template, index + 1, '}')) return .{ .malformed = offset + index };

            index += 2;

            continue;
        }

        if (byte != '{') {
            index += 1;

            continue;
        }

        if (byte_is(template, index + 1, '{')) {
            index += 2;

            continue;
        }

        index = format_field(template, index, offset, out) catch |err| switch (err) {
            error.Malformed => return .{ .malformed = offset + index },
            error.Overflow, error.Truncated => return .overflow,
        };
    }

    assert(index == template.len);

    return .complete;
}

fn byte_is(bytes: []const u8, index: u32, expected: u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(index <= bytes.len);

    if (index == bytes.len) return false;
    return bytes[index] == expected;
}

fn buffer_push(out: *Buffer, bytes: []const u8) error{Truncated}!void {
    assert(bytes.len <= std.math.maxInt(u32));

    if (bytes.len > out.unused_capacity()) return error.Truncated;

    const before = out.count();

    out.push_slice(bytes);

    assert(out.count() == before + bytes.len);
}

fn prefix_end_of(token: []const u8) ?u32 {
    assert(token.len <= std.math.maxInt(u32));

    const window = token[0..@min(token.len, prefix_length_max + 1)];
    const end: u32 = @intCast(std.mem.findAny(u8, window, "\"'") orelse return null);
    const letters = token[0..end];

    assert(end <= prefix_length_max);
    assert(token[end] == '"' or token[end] == '\'');

    for (letters) |byte| {
        if (!is_prefix_letter(byte)) return null;
    }

    if (letters.len == 2) {
        const head = std.ascii.toLower(letters[0]);
        const tail = std.ascii.toLower(letters[1]);
        const head_raw = head == 'r' and std.mem.findScalar(u8, "bft", tail) != null;
        const tail_raw = tail == 'r' and std.mem.findScalar(u8, "bft", head) != null;
        const pairs = head_raw or tail_raw;
        if (!pairs) return null;
    }

    return end;
}

fn is_prefix_letter(byte: u8) bool {
    if (!std.ascii.isAlphabetic(byte)) return false;

    const result = std.mem.findScalar(u8, "BFRTUbfrtu", byte) != null;

    if (result) assert(std.ascii.isAlphabetic(byte));
    if (result) assert(byte != '"');

    return result;
}

fn quote_of(bytes: []const u8) ?Quote {
    if (bytes.len == 0) return null;

    const byte = bytes[0];
    const quoted = byte == '"' or byte == '\'';
    if (!quoted) return null;

    const triple = bytes.len >= 3 and bytes[1] == byte and bytes[2] == byte;

    if (triple) {
        if (bytes.len < 6) return null;
    }

    assert(byte == '"' or byte == '\'');
    if (triple) assert(bytes.len >= 6);

    return .{ .byte = byte, .triple = triple };
}

fn decode_into(token: []const u8, out: *Buffer, origins: ?*Origins) Outcome {
    assert(token.len <= std.math.maxInt(u32));
    if (origins) |held| assert(held.count() == out.count());

    const shape = shape_of(token, 0) orelse return .{ .malformed = 0 };
    const content = shape.content.text(token);
    const base = shape.content.offset;

    assert(base >= 1);
    assert(content.len < token.len);

    if (shape.prefix.raw) {
        buffer_push(out, content) catch return .overflow;

        if (origins) |held| origins_push(held, content, content, 0, base) catch return .overflow;
        return .complete;
    }

    var offset: u32 = 0;

    while (offset < content.len) {
        const written = out.count();
        const plain = content[offset] != '\\';

        const next = if (plain)
            offset + 1
        else
            escape_of(content, offset, shape.prefix.bytes, out) catch |err| switch (err) {
                error.Malformed => return .{ .malformed = base + offset },
                error.Truncated => return .overflow,
            };

        assert(next > offset);

        if (plain) buffer_push(out, content[offset..next]) catch return .overflow;

        if (origins) |held| {
            const pushed = out.const_slice()[written..];

            origins_push(held, pushed, content[offset..next], offset, base) catch return .overflow;
        }

        offset = next;
    }

    assert(offset == content.len);

    return .complete;
}

fn origins_push(
    origins: *Origins,
    pushed: []const u8,
    read: []const u8,
    offset: u32,
    base: u32,
) error{Truncated}!void {
    assert(read.len > 0 or pushed.len == 0);
    assert(offset < std.math.maxInt(u32));
    assert(base < std.math.maxInt(u32));

    const kept = std.mem.eql(u8, pushed, read);

    if (pushed.len > origins.unused_capacity()) return error.Truncated;

    for (0..pushed.len) |index| {
        const origin = base + offset + @as(u32, @intCast(index));

        origins.push(if (kept) origin else origin_escaped);
    }
}

fn escape_of(content: []const u8, offset: u32, bytes: bool, out: *Buffer) Escape!u32 {
    assert(offset < content.len);
    assert(content[offset] == '\\');

    if (offset + 1 == content.len) {
        try buffer_push(out, "\\");

        assert(offset + 1 == content.len);

        return offset + 1;
    }

    const byte = content[offset + 1];

    if (byte == '\n') {
        assert(offset + 2 <= content.len);

        return offset + 2;
    }

    if (byte == '\r') {
        assert(offset + 2 + @intFromBool(byte_is(content, offset + 2, '\n')) <= content.len);

        return offset + 2 + @intFromBool(byte_is(content, offset + 2, '\n'));
    }

    if (simple_escape_of(byte)) |mapped| {
        try buffer_push(out, &.{mapped});

        assert(offset + 2 <= content.len);

        return offset + 2;
    }

    if (is_octal_digit(byte)) return octal_escape(content, offset, bytes, out);
    if (byte == 'x') return hex_escape(content, offset, 2, bytes, out);

    if (!bytes) {
        if (byte == 'N') return error.Malformed;
        if (byte == 'u') return hex_escape(content, offset, 4, bytes, out);
        if (byte == 'U') return hex_escape(content, offset, 8, bytes, out);
    }

    try buffer_push(out, content[offset..][0..2]);

    assert(offset + 2 <= content.len);

    return offset + 2;
}

fn simple_escape_of(byte: u8) ?u8 {
    if (!std.ascii.isPrint(byte)) return null;

    const result: ?u8 = switch (byte) {
        '"' => '"',
        '\'' => '\'',
        '\\' => '\\',
        'a' => 0x07,
        'b' => 0x08,
        'f' => 0x0C,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'v' => 0x0B,
        else => null,
    };

    if (result) |mapped| assert(mapped <= byte);
    if (result != null) assert(!is_octal_digit(byte));

    return result;
}

fn is_octal_digit(byte: u8) bool {
    if (byte < '0') return false;

    const result = byte >= '0' and byte <= '7';

    if (result) assert(std.ascii.isDigit(byte));
    if (result) assert(byte - '0' < 8);

    return result;
}

fn octal_escape(content: []const u8, offset: u32, bytes: bool, out: *Buffer) Escape!u32 {
    assert(offset + 1 < content.len);
    assert(is_octal_digit(content[offset + 1]));

    var value: u32 = 0;
    var read: u32 = 0;

    while (read < octal_width_max) : (read += 1) {
        const at = offset + 1 + read;
        if (at == content.len) break;
        if (!is_octal_digit(content[at])) break;

        value = value * 8 + (content[at] - '0');
    }

    assert(read >= 1);
    assert(value <= 0o777);

    return code_point_push(value, bytes, out, offset + 1 + read);
}

fn hex_escape(
    content: []const u8,
    offset: u32,
    width: u32,
    bytes: bool,
    out: *Buffer,
) Escape!u32 {
    assert(offset + 1 < content.len);
    assert(width == 2 or width == 4 or width == 8);

    if (content.len - offset < 2 + width) return error.Malformed;

    const end = offset + 2 + width;
    var value: u32 = 0;

    for (content[offset + 2 .. end]) |byte| {
        const digit = std.fmt.charToDigit(byte, 16) catch return error.Malformed;

        value = value * 16 + digit;
    }

    return code_point_push(value, bytes, out, end);
}

fn code_point_push(value: u32, bytes: bool, out: *Buffer, next: u32) Escape!u32 {
    assert(next >= 2);
    assert(value < std.math.maxInt(u32));

    var encoded: [4]u8 = undefined;
    const length = code_point_encode(value, bytes, &encoded) orelse return error.Malformed;

    assert(length >= 1);
    assert(length <= encoded.len);

    try buffer_push(out, encoded[0..length]);

    return next;
}

fn code_point_encode(value: u32, bytes: bool, encoded: *[4]u8) ?u32 {
    assert(value < std.math.maxInt(u32));

    const single = bytes or value < 0x80;

    if (single) {
        if (value > 0xFF) return null;

        encoded[0] = @intCast(value);

        return 1;
    }

    if (value > 0x10FFFF) return null;

    const length = std.unicode.wtf8Encode(@intCast(value), encoded) catch unreachable;

    assert(length >= 2);
    assert(length <= 4);

    return length;
}

fn radix_of(text: []const u8) u8 {
    assert(text.len > 0);

    if (text.len < 2) return 10;
    if (text[0] != '0') return 10;

    const result: u8 = switch (text[1]) {
        'B', 'b' => 2,
        'O', 'o' => 8,
        'X', 'x' => 16,
        else => 10,
    };

    assert(result >= 2);
    assert(result <= 16);

    return result;
}

fn integer_of(text: []const u8, radix: u8) Number {
    assert(radix >= 2);
    assert(radix <= 16);
    assert(text.len <= std.math.maxInt(u32));

    var value: u64 = 0;
    var digits: u32 = 0;

    for (text) |byte| {
        if (byte == '_') continue;

        const digit = std.fmt.charToDigit(byte, radix) catch return .overflow;
        const scaled = std.math.mul(u64, value, radix) catch return .overflow;

        value = std.math.add(u64, scaled, digit) catch return .overflow;
        digits += 1;
    }

    if (digits == 0) return .overflow;

    assert(digits <= text.len);

    return .{ .integer = value };
}

fn percent_field(template: []const u8, start: u32, offset: u32, out: *PercentFields) Escape!u32 {
    assert(start < template.len);
    assert(template[start] == '%');
    assert(offset < std.math.maxInt(u32));

    var index = start + 1;
    const key = percent_key(template, &index, offset) orelse return error.Malformed;

    while (index < template.len) : (index += 1) {
        if (std.mem.findScalar(u8, "# +-0", template[index]) == null) break;
    }

    const width_star = percent_width(template, &index);
    var precision_star = false;

    if (byte_is(template, index, '.')) {
        index += 1;
        precision_star = percent_width(template, &index);
    }

    while (index < template.len) : (index += 1) {
        if (std.mem.findScalar(u8, "Lhl", template[index]) == null) break;
    }

    if (index == template.len) return error.Malformed;

    const conversion = template[index];
    if (std.mem.findScalar(u8, conversions, conversion) == null) return error.Malformed;
    if (out.full()) return error.Truncated;

    out.push(.{
        .conversion = conversion,
        .key = key,
        .precision_star = precision_star,
        .span = .{ .offset = offset + start, .length = index + 1 - start },
        .width_star = width_star,
    });

    assert(index > start);

    return index + 1;
}

fn percent_key(template: []const u8, index: *u32, offset: u32) ?Span {
    assert(index.* >= 1);
    assert(index.* <= template.len);
    assert(offset < std.math.maxInt(u32));

    if (!byte_is(template, index.*, '(')) return Span.empty;

    const start = index.* + 1;
    var end = start;
    var depth: u32 = 1;

    while (end < template.len) : (end += 1) {
        if (template[end] == '(') depth += 1;
        if (template[end] == ')') depth -= 1;
        if (depth == 0) break;
    }

    if (depth > 0) return null;

    assert(template[end] == ')');

    index.* = end + 1;

    return .{ .offset = offset + start, .length = end - start };
}

fn percent_width(template: []const u8, index: *u32) bool {
    assert(template.len <= std.math.maxInt(u32));

    if (byte_is(template, index.*, '*')) {
        index.* += 1;

        return true;
    }

    while (index.* < template.len) : (index.* += 1) {
        if (!std.ascii.isDigit(template[index.*])) break;
    }

    assert(index.* <= template.len);

    return false;
}

fn format_field(template: []const u8, start: u32, offset: u32, out: *FormatFields) Failure!u32 {
    assert(template.len <= std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    const read = try field_of(template, start, offset, true);
    const specification = read.field.specification;

    if (out.full()) return error.Truncated;

    out.push(read.field);

    if (specification.length == 0) return read.next;

    const base = specification.offset - offset;
    const end = base + specification.length;

    assert(start < base);
    assert(end < read.next);

    try specification_fields(template, base, end, offset, out);

    return read.next;
}

fn format_field_nested(
    template: []const u8,
    start: u32,
    offset: u32,
    out: *FormatFields,
) Failure!u32 {
    assert(template.len <= std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    const read = try field_of(template, start, offset, false);

    assert(start < read.next);
    assert(read.next <= template.len);

    if (out.full()) return error.Truncated;

    out.push(read.field);

    return read.next;
}

fn field_of(template: []const u8, start: u32, offset: u32, nested: bool) Failure!FieldRead {
    assert(start < template.len);
    assert(template[start] == '{');
    assert(offset < std.math.maxInt(u32));

    var index = field_name_end(template, start + 1) orelse return error.Malformed;

    const name = field_name_of(template[start + 1 .. index], offset, start + 1) orelse
        return error.Overflow;

    var conversion: u8 = 0;

    if (byte_is(template, index, '!')) {
        if (index + 1 == template.len) return error.Malformed;

        const held = template[index + 1];
        if (std.mem.findScalar(u8, "ars", held) == null) return error.Malformed;

        conversion = held;
        index += 2;
    }

    var specification: Span = .empty;

    if (byte_is(template, index, ':')) {
        const opened = index + 1;

        index = specification_end(template, opened, nested) orelse return error.Malformed;
        specification = .{ .offset = offset + opened, .length = index - opened };
    }

    if (!byte_is(template, index, '}')) return error.Malformed;

    assert(start < index);

    return .{
        .field = .{
            .conversion = conversion,
            .name = name,
            .span = .{ .offset = offset + start, .length = index + 1 - start },
            .specification = specification,
        },
        .next = index + 1,
    };
}

fn specification_fields(
    template: []const u8,
    start: u32,
    end: u32,
    offset: u32,
    out: *FormatFields,
) Failure!void {
    assert(start <= end);
    assert(end <= template.len);
    assert(offset < std.math.maxInt(u32));

    var index = start;

    while (index < end) {
        const byte = template[index];
        const brace = byte == '{' or byte == '}';
        const escaped = brace and byte_is(template, index + 1, byte);

        if (escaped) {
            index += 2;

            continue;
        }

        if (byte != '{') {
            index += 1;

            continue;
        }

        const next = try format_field_nested(template, index, offset, out);

        assert(next > index);

        index = next;
    }
}

fn field_name_end(template: []const u8, start: u32) ?u32 {
    assert(start >= 1);
    assert(start <= template.len);

    var index = start;
    var depth: u32 = 0;

    while (index < template.len) : (index += 1) {
        const byte = template[index];
        if (byte == '{') return null;

        if (byte == '[') depth += 1;
        if (byte == ']') depth -|= 1;

        const stop = depth == 0 and (byte == '!' or byte == ':' or byte == '}');
        if (stop) return index;
    }

    return index;
}

fn field_name_of(bytes: []const u8, offset: u32, at: u32) ?FieldName {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(std.mem.findScalar(u8, bytes, '{') == null);
    assert(offset < std.math.maxInt(u32));
    assert(at < std.math.maxInt(u32));

    const head: u32 = @intCast(std.mem.findAny(u8, bytes, ".[") orelse bytes.len);
    if (head == 0) return .auto;

    const digits = for (bytes[0..head]) |byte| {
        if (!std.ascii.isDigit(byte)) break false;
    } else true;

    if (!digits) return .{ .keyword = .{ .offset = offset + at, .length = head } };

    var value: u32 = 0;

    for (bytes[0..head]) |byte| {
        const scaled = std.math.mul(u32, value, 10) catch return null;

        value = std.math.add(u32, scaled, byte - '0') catch return null;
    }

    return .{ .positional = value };
}

fn specification_end(template: []const u8, start: u32, nested: bool) ?u32 {
    assert(start >= 1);
    assert(start <= template.len);

    var index = start;
    var depth: u32 = 0;

    while (index < template.len) {
        const byte = template[index];
        const brace = byte == '{' or byte == '}';
        const escaped = brace and depth == 0 and byte_is(template, index + 1, byte);

        if (escaped) {
            index += 2;

            continue;
        }

        if (byte == '{') {
            depth += 1;

            if (depth > 1) return null;
            if (!nested) return null;
        }

        if (byte == '}') {
            if (depth == 0) return index;

            depth -= 1;
        }

        index += 1;
    }

    return null;
}

fn decoded(token: []const u8, out: *Buffer) ?[]const u8 {
    assert(token.len >= 2);
    assert(out.capacity() >= 1);

    out.clear();

    if (decode(token, out) != .complete) return null;
    return out.const_slice();
}

fn formats(template: []const u8, out: *FormatFields) ?[]const FormatField {
    assert(template.len > 0);
    assert(out.capacity() >= 1);

    out.clear();

    if (format_fields(template, 0, out) != .complete) return null;
    return out.const_slice();
}

fn percents(template: []const u8, out: *PercentFields) ?[]const PercentField {
    assert(template.len > 0);
    assert(out.capacity() >= 1);

    out.clear();

    if (percent_fields(template, 0, out) != .complete) return null;
    return out.const_slice();
}

test "a plain string reads its quote and its content" {
    const held = shape_of("'text'", 10).?;

    try std.testing.expectEqual('\'', held.quote.byte);
    try std.testing.expect(!held.quote.triple);
    try std.testing.expectEqual(11, held.content.offset);
    try std.testing.expectEqual(4, held.content.length);
    try std.testing.expectEqual(Prefix{}, held.prefix);
}

test "a triple quoted string reads three quotes a side" {
    const held = shape_of("\"\"\"text\"\"\"", 0).?;

    try std.testing.expect(held.quote.triple);
    try std.testing.expectEqual(3, held.content.offset);
    try std.testing.expectEqual(4, held.content.length);
}

test "an empty string reads as a shape with no content" {
    try std.testing.expectEqual(0, shape_of("''", 0).?.content.length);
    try std.testing.expectEqual(0, shape_of("''''''", 0).?.content.length);
}

test "every prefix letter reads into its own flag" {
    try std.testing.expect(shape_of("rb'text'", 0).?.prefix.bytes);
    try std.testing.expect(shape_of("rb'text'", 0).?.prefix.raw);
    try std.testing.expect(shape_of("F'text'", 0).?.prefix.format);
    try std.testing.expect(shape_of("t'text'", 0).?.prefix.template);
    try std.testing.expect(shape_of("U'text'", 0).?.prefix.unicode);
}

test "a prefix of three letters is no prefix python spells" {
    try std.testing.expect(shape_of("rbu'text'", 0) == null);
    try std.testing.expect(shape_of("q'text'", 0) == null);
    try std.testing.expect(shape_of("text", 0) == null);
}

test "a quote that never closes reads as no shape" {
    try std.testing.expect(shape_of("'text", 0) == null);
    try std.testing.expect(shape_of("'text\"", 0) == null);
    try std.testing.expect(shape_of("'''", 0) == null);
    try std.testing.expect(shape_of("''''", 0) == null);
    try std.testing.expect(shape_of("'''x''", 0) == null);
}

test "a raw bytes triple reads its prefix and its content" {
    const held = shape_of("rb'''x'''", 4).?;

    try std.testing.expect(held.prefix.raw);
    try std.testing.expect(held.prefix.bytes);
    try std.testing.expect(held.quote.triple);
    try std.testing.expectEqual(9, held.content.offset);
    try std.testing.expectEqual(1, held.content.length);
}

test "a pair python never spells is no prefix" {
    try std.testing.expect(shape_of("bu'text'", 0) == null);
    try std.testing.expect(shape_of("tb'text'", 0) == null);
    try std.testing.expect(shape_of("ur'text'", 0) == null);
    try std.testing.expect(shape_of("rr'text'", 0) == null);
    try std.testing.expect(shape_of("Rt'text'", 0) != null);
    try std.testing.expect(shape_of("fR'text'", 0) != null);
}

test "every escape decodes the way cpython encodes it" {
    var out: Buffer = try .init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "aA\xc3\xa9A\n",
        decoded("\"a\\x41\\u00e9\\101\\n\"", &out).?,
    );

    try std.testing.expectEqualStrings("A\\u00e9", decoded("b\"\\x41\\u00e9\"", &out).?);
    try std.testing.expectEqualStrings("\xc3\xbf", decoded("\"\\377\"", &out).?);
    try std.testing.expectEqualStrings("\xff", decoded("b\"\\377\"", &out).?);
    try std.testing.expectEqualStrings("\xc3\xa9", decoded("\"\\xe9\"", &out).?);
    try std.testing.expectEqualStrings("\xe9", decoded("b\"\\xe9\"", &out).?);
}

test "each single byte escape maps to its own byte" {
    var out: Buffer = try .init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "\x07\x08\x0c\n\r\t\x0b\\'\"",
        decoded("\"\\a\\b\\f\\n\\r\\t\\v\\\\\\'\\\"\"", &out).?,
    );
}

test "an unknown escape keeps its backslash the way cpython keeps it" {
    var out: Buffer = try .init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\\q", decoded("\"\\q\"", &out).?);
    try std.testing.expectEqualStrings("\\q", decoded("b\"\\q\"", &out).?);
    try std.testing.expectEqualStrings("\\N{X}", decoded("b\"\\N{X}\"", &out).?);
}

test "a named escape is the one form the decoder refuses" {
    var out: Buffer = try .init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    try std.testing.expect(decoded("\"\\N{DASH}\"", &out) == null);
}

test "a malformed hexadecimal escape refuses rather than guesses" {
    var out: Buffer = try .init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    try std.testing.expect(decoded("\"\\x4\"", &out) == null);
    try std.testing.expect(decoded("\"\\xzz\"", &out) == null);
    try std.testing.expect(decoded("\"\\u00e\"", &out) == null);
}

test "a raw string copies its content byte for byte" {
    var out: Buffer = try .init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a\\x41\\n", decoded("r\"a\\x41\\n\"", &out).?);
}

test "a backslash before a newline drops both" {
    var out: Buffer = try .init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ab", decoded("\"a\\\nb\"", &out).?);
    try std.testing.expectEqualStrings("ab", decoded("\"a\\\r\nb\"", &out).?);
}

test "a buffer that fills reports the decode incomplete" {
    var out: Buffer = try .init(std.testing.allocator, 2);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(Outcome, .overflow), decode("\"abcd\"", &out));

    var narrow: Buffer = try .init(std.testing.allocator, 1);
    defer narrow.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(Outcome, .overflow), decode("\"\\u00e9\"", &narrow));
    try std.testing.expectEqual(Outcome{ .malformed = 1 }, decode("\"\\N{X}\"", &narrow));
}

test "a traced decode maps each kept byte to its source and each escape to none" {
    var out: Buffer = try .init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    var origins: Origins = try .init(std.testing.allocator, 1 << 8);
    defer origins.deinit(std.testing.allocator);

    const none = origin_escaped;

    try std.testing.expectEqual(Outcome.complete, decode_traced("'a\\'b\\q'", &out, &origins));
    try std.testing.expectEqualStrings("a'b\\q", out.const_slice());
    try std.testing.expectEqualSlices(u32, &.{ 1, none, 4, 5, 6 }, origins.const_slice());

    out.clear();
    origins.clear();

    try std.testing.expectEqual(Outcome.complete, decode_traced("r'a\\b'", &out, &origins));
    try std.testing.expectEqualStrings("a\\b", out.const_slice());
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4 }, origins.const_slice());

    out.clear();
    origins.clear();

    try std.testing.expectEqual(Outcome.complete, decode_traced("'a\\\nb\\x41'", &out, &origins));
    try std.testing.expectEqualStrings("abA", out.const_slice());
    try std.testing.expectEqualSlices(u32, &.{ 1, 4, none }, origins.const_slice());
}

test "a lone surrogate writes the bytes wtf8 gives it" {
    var out: Buffer = try .init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\xed\xa0\x80", decoded("\"\\ud800\"", &out).?);
    try std.testing.expectEqualStrings("A", decoded("\"\\U00000041\"", &out).?);
    try std.testing.expect(decoded("\"\\U00110000\"", &out) == null);
}

test "a digit past seven is no octal escape at all" {
    var out: Buffer = try .init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\\8\\9", decoded("\"\\8\\9\"", &out).?);
    try std.testing.expectEqualStrings("\x018", decoded("\"\\18\"", &out).?);
}

test "a number reads its radix the way cpython reads it" {
    try std.testing.expectEqual(Number{ .integer = 255 }, number_of("0x_ff"));
    try std.testing.expectEqual(Number{ .integer = 1000 }, number_of("1_000"));
    try std.testing.expectEqual(Number{ .integer = 15 }, number_of("0o17"));
    try std.testing.expectEqual(Number{ .integer = 10 }, number_of("0b1010"));
    try std.testing.expectEqual(Number{ .integer = 0 }, number_of("0"));
}

test "a radix with no digit after it spells no value" {
    try std.testing.expectEqual(@as(Number, .overflow), number_of("0x"));
    try std.testing.expectEqual(@as(Number, .overflow), number_of("0b_"));
}

test "a float and a complex read as themselves" {
    try std.testing.expectEqual(@as(Number, .float), number_of("1.5"));
    try std.testing.expectEqual(@as(Number, .float), number_of("1e10"));
    try std.testing.expectEqual(@as(Number, .float), number_of("1E10"));
    try std.testing.expectEqual(@as(Number, .complex), number_of("1j"));
    try std.testing.expectEqual(@as(Number, .complex), number_of("1.5J"));
}

test "a hexadecimal e is a digit rather than an exponent" {
    try std.testing.expectEqual(Number{ .integer = 485 }, number_of("0x1e5"));
}

test "a number past the word reads as an overflow" {
    try std.testing.expectEqual(
        Number{ .integer = std.math.maxInt(u64) },
        number_of("18446744073709551615"),
    );

    try std.testing.expectEqual(@as(Number, .overflow), number_of("18446744073709551616"));
}

test "a percent template reads one field per conversion" {
    var out: PercentFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    const held = percents("%(name)s %*d %.2f %%", &out).?;

    try std.testing.expectEqual(3, held.len);
    try std.testing.expectEqual('s', held[0].conversion);
    try std.testing.expectEqual(2, held[0].key.offset);
    try std.testing.expectEqual(4, held[0].key.length);
    try std.testing.expectEqual(0, held[0].span.offset);
    try std.testing.expectEqual(8, held[0].span.length);
    try std.testing.expect(held[1].width_star);
    try std.testing.expectEqual('d', held[1].conversion);
    try std.testing.expect(!held[2].width_star);
    try std.testing.expect(!held[2].precision_star);
    try std.testing.expectEqual('f', held[2].conversion);
}

test "a starred precision reads as a star" {
    var out: PercentFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    const held = percents("%.*f", &out).?;

    try std.testing.expect(held[0].precision_star);
    try std.testing.expect(!held[0].width_star);
}

test "a percent template python refuses names where" {
    var out: PercentFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome{ .malformed = 13 }, percent_fields("ab %z", 10, &out));
    try std.testing.expectEqual(Outcome{ .malformed = 0 }, percent_fields("%(name", 0, &out));
}

test "a key balances its own parentheses the way cpython counts them" {
    var out: PercentFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    const held = percents("%(a(b))s", &out).?;

    try std.testing.expectEqual(1, held.len);
    try std.testing.expectEqual(2, held[0].key.offset);
    try std.testing.expectEqual(4, held[0].key.length);
    try std.testing.expect(percents("%(a(b)s", &out) == null);
}

test "every flag and length modifier steps to the conversion" {
    var out: PercentFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    const held = percents("%-05.2ld", &out).?;

    try std.testing.expectEqual(1, held.len);
    try std.testing.expectEqual('d', held[0].conversion);
    try std.testing.expectEqual(8, held[0].span.length);
    try std.testing.expect(!held[0].width_star);
    try std.testing.expect(!held[0].precision_star);
}

test "a full table is an overflow rather than a malformed template" {
    var percent: PercentFields = try .init(std.testing.allocator, 1);
    defer percent.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(Outcome, .overflow), percent_fields("%s%s", 0, &percent));

    var format: FormatFields = try .init(std.testing.allocator, 1);
    defer format.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(Outcome, .overflow), format_fields("{}{}", 0, &format));
    try std.testing.expectEqual(1, format.count());
}

test "a format template reads its names the way cpython reads them" {
    var out: FormatFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    const held = formats("{} {0} {name!r:>{w}} {{x}}", &out).?;

    try std.testing.expectEqual(4, held.len);
    try std.testing.expectEqual(@as(FieldName, .auto), held[0].name);
    try std.testing.expectEqual(FieldName{ .positional = 0 }, held[1].name);
    try std.testing.expectEqual('r', held[2].conversion);
    try std.testing.expectEqual(15, held[2].specification.offset);
    try std.testing.expectEqual(4, held[2].specification.length);

    const name = held[2].name.keyword;

    try std.testing.expectEqual(8, name.offset);
    try std.testing.expectEqual(4, name.length);

    const width = held[3].name.keyword;

    try std.testing.expectEqual(17, width.offset);
    try std.testing.expectEqual(1, width.length);
}

test "a colon inside an index closes no specification" {
    var out: FormatFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    const held = formats("{a[b:c]}", &out).?;

    try std.testing.expectEqual(1, held.len);
    try std.testing.expectEqual(Span.empty, held[0].specification);

    const name = held[0].name.keyword;

    try std.testing.expectEqual(1, name.length);
}

test "a name opening with an index or an attribute is automatic" {
    var out: FormatFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(FieldName, .auto), formats("{[0]}", &out).?[0].name);
    try std.testing.expectEqual(@as(FieldName, .auto), formats("{.attr}", &out).?[0].name);
}

test "a dotted keyword names the head alone" {
    var out: FormatFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    const held = formats("{0[1]!s:>{1}}", &out).?;

    try std.testing.expectEqual(FieldName{ .positional = 0 }, held[0].name);
    try std.testing.expectEqual('s', held[0].conversion);
}

test "a format template python refuses names where" {
    var out: FormatFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome{ .malformed = 0 }, format_fields("{", 0, &out));
    try std.testing.expectEqual(Outcome{ .malformed = 1 }, format_fields("a}", 0, &out));
    try std.testing.expect(formats("{a!z}", &out) == null);
    try std.testing.expect(formats("{a{b}", &out) == null);
    try std.testing.expect(formats("{:{:{}}}", &out) == null);
}

test "a doubled brace inside a specification is a literal one" {
    var out: FormatFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    const held = formats("{a:{{b}}}", &out).?;

    try std.testing.expectEqual(1, held.len);
    try std.testing.expectEqual(5, held[0].specification.length);
}

test "a field nested in a specification consumes an argument of its own" {
    var out: FormatFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    const held = formats("{:{}}", &out).?;

    try std.testing.expectEqual(2, held.len);
    try std.testing.expectEqual(5, held[0].span.length);
    try std.testing.expectEqual(2, held[1].span.offset);
    try std.testing.expectEqual(2, held[1].span.length);
    try std.testing.expectEqual(@as(FieldName, .auto), held[1].name);

    const plan = formats("{0}{}{key.attr[0]!s:>{1}}", &out).?;

    try std.testing.expectEqual(4, plan.len);
    try std.testing.expectEqual(FieldName{ .positional = 0 }, plan[0].name);
    try std.testing.expectEqual(@as(FieldName, .auto), plan[1].name);
    try std.testing.expectEqual('s', plan[2].conversion);
    try std.testing.expectEqual(4, plan[2].specification.length);
    try std.testing.expectEqual(FieldName{ .positional = 1 }, plan[3].name);
}

test "a positional index past a word is an overflow rather than a guess" {
    var out: FormatFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(Outcome, .complete), format_fields("{4294967295}", 0, &out));
    try std.testing.expectEqual(@as(Outcome, .overflow), format_fields("{4294967296}", 0, &out));
}

test "a doubled brace carries no field" {
    var out: FormatFields = try .init(std.testing.allocator, field_count_max_default);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, formats("{{}}", &out).?.len);
}
