const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Tokens = @import("tokens.zig").Tokens;
const Vocabulary = @import("vocabulary.zig").Vocabulary;
const scan = @import("../../text/scan.zig");
const token = @import("token.zig");
const Dialect = Vocabulary.Dialect;
const RawTextTag = Vocabulary.RawTextTag;

const Lexer = struct {
    after_equals: bool,
    after_name: bool,
    dialect: Dialect,
    length: u32,
    mode: Mode,
    position: u32,
    raw_pending: ?RawKind,
    raw_text_tags: []const RawTextTag,
    script_escape: ScriptEscape,
    source: []const u8,
    tokens: *Tokens,
    truncated: bool,
    value_unquoted: bool,
    verbatim_stop: ?u32,

    fn init(
        source: []const u8,
        tokens: *Tokens,
        raw_text_tags: []const RawTextTag,
        dialect: Dialect,
    ) Lexer {
        assert(source.len <= std.math.maxInt(u32));
        assert(raw_text_tags.len <= std.math.maxInt(u32));

        const length = token.source_length(source);

        assert(tokens.count() == 0);
        assert(tokens.end_previous == 0);

        return .{
            .after_equals = false,
            .after_name = false,
            .dialect = dialect,
            .length = length,
            .mode = .text,
            .position = 0,
            .raw_pending = null,
            .raw_text_tags = raw_text_tags,
            .script_escape = .none,
            .source = source,
            .tokens = tokens,
            .truncated = false,
            .value_unquoted = false,
            .verbatim_stop = null,
        };
    }

    fn run(lexer: *Lexer) error{Truncated}!void {
        while (lexer.position < lexer.length) {
            const start = lexer.position;

            lexer.step();

            if (lexer.truncated) break;

            if (lexer.position <= start) {
                lexer.push(.error_token, start, lexer.length);
                lexer.position = lexer.length;

                break;
            }
        }

        if (lexer.truncated) {
            const start = lexer.tokens.end_previous;

            assert(start < lexer.length);

            lexer.tokens.push(.error_token, .between(start, lexer.length)) catch unreachable;

            assert(lexer.tokens.end_previous == lexer.length);

            return error.Truncated;
        }

        assert(lexer.position == lexer.length);
        assert(lexer.tokens.end_previous == lexer.length);
    }

    fn step(lexer: *Lexer) void {
        assert(lexer.position < lexer.length);
        assert(!lexer.truncated);

        switch (lexer.mode) {
            .attribute_value => |quote| lexer.step_attribute_value(quote),
            .declaration => lexer.step_declaration(),
            .html_comment => lexer.step_html_comment(),
            .raw_text => |kind| lexer.step_raw_text(kind),
            .tag => lexer.step_tag(),
            .text => lexer.step_text(),
        }
    }

    fn step_attribute_value(lexer: *Lexer, quote: u8) void {
        assert(lexer.mode == .attribute_value);
        assert(quote == '"' or quote == '\'');

        if (lexer.lex_template_construct()) return;

        const start = lexer.position;

        if (lexer.byte_at(start) == quote) {
            lexer.advance(1);
            lexer.push(.quote, start, lexer.position);

            lexer.mode = .tag;
            lexer.after_equals = false;

            return;
        }

        while (lexer.position < lexer.length) {
            if (lexer.byte_at(lexer.position) == quote) break;
            if (lexer.is_template_open(lexer.position)) break;

            lexer.advance(1);
        }

        lexer.push(.attribute_text, start, lexer.position);
    }

    fn step_declaration(lexer: *Lexer) void {
        assert(lexer.dialect == .django);
        assert(lexer.mode == .declaration);

        if (lexer.lex_template_construct()) return;

        lexer.lex_declaration_rest(lexer.position);
    }

    fn step_html_comment(lexer: *Lexer) void {
        assert(lexer.mode == .html_comment);
        assert(lexer.position < lexer.length);

        if (lexer.lex_template_construct()) return;

        const start = lexer.position;

        if (lexer.matches_at(start, "-->")) {
            lexer.advance(3);
            lexer.push(.html_comment_close, start, lexer.position);

            lexer.mode = .text;

            return;
        }

        lexer.advance(1);
        lexer.scan_while(continues_comment_text);
        lexer.push(.text, start, lexer.position);
    }

    fn step_raw_text(lexer: *Lexer, kind: RawKind) void {
        assert(lexer.mode == .raw_text);
        assert(lexer.position < lexer.length);

        if (lexer.lex_template_construct()) return;

        if (lexer.is_raw_text_end(lexer.position, kind)) {
            lexer.lex_close_tag_name();

            return;
        }

        const start = lexer.position;

        lexer.advance(1);
        lexer.scan_while(continues_text);
        lexer.push(kind.text_kind(), start, lexer.position);

        if (kind == .script) lexer.script_escape_step(start, lexer.position);
    }

    fn script_escape_step(lexer: *Lexer, start: u32, end: u32) void {
        assert(start < end);
        assert(end <= lexer.length);

        var search = start;

        if (lexer.byte_at(start) == '<') {
            switch (lexer.script_escape) {
                .none => if (lexer.matches_at(start, "<!--")) {
                    lexer.script_escape = .escaped;
                    search = start + 2;
                },
                .escaped => if (lexer.is_name_delimited_at(start + 1, "script")) {
                    lexer.script_escape = .double;
                },
                .double => if (lexer.is_end_tag_at(start, "script")) {
                    lexer.script_escape = .escaped;
                },
            }
        }

        if (lexer.script_escape == .none) return;
        if (std.mem.find(u8, lexer.source[search..end], "-->") == null) return;

        lexer.script_escape = .none;
    }

    fn step_tag(lexer: *Lexer) void {
        assert(lexer.mode == .tag);
        assert(lexer.position < lexer.length);

        const value_open = lexer.after_equals or lexer.value_unquoted;

        if (lexer.lex_template_construct()) {
            if (lexer.dialect == .django) lexer.value_continue(value_open);

            return;
        }

        const byte = lexer.byte_at(lexer.position) orelse return;

        if (scan.is_ascii_whitespace(byte)) {
            lexer.lex_whitespace();
            lexer.value_unquoted = false;

            return;
        }

        if (lexer.lex_tag_punctuation(byte)) return;
        if (lexer.dialect == .django) return lexer.lex_tag_run();

        const start = lexer.position;

        if (lexer.after_equals) {
            lexer.scan_while(continues_unquoted_value);
            lexer.push(.attribute_text, start, lexer.position);

            lexer.after_equals = false;
            lexer.after_name = false;
        } else {
            assert(byte != '/');
            assert(byte != '>');
            assert(!lexer.is_template_open(start));

            lexer.advance(1);
            lexer.scan_while(continues_attribute_name);
            lexer.push(.attribute_name, start, lexer.position);

            lexer.after_name = true;
        }
    }

    fn step_text(lexer: *Lexer) void {
        assert(lexer.mode == .text);
        assert(lexer.position < lexer.length);

        if (lexer.lex_template_construct()) return;

        if (lexer.byte_at(lexer.position) == '<') {
            lexer.lex_angle();

            return;
        }

        const start = lexer.position;

        lexer.scan_while(continues_text);
        lexer.push(.text, start, lexer.position);
    }

    fn lex_angle(lexer: *Lexer) void {
        assert(lexer.mode == .text);
        assert(lexer.byte_at(lexer.position) == '<');

        const start = lexer.position;

        if (lexer.matches_at(start, "<!--")) {
            lexer.advance(4);
            lexer.push(.html_comment_open, start, lexer.position);
            lexer.mode = .html_comment;

            return;
        }

        if (lexer.matches_at(start, "<!")) return lexer.lex_markup_declaration();
        if (lexer.matches_at(start, "<?")) return lexer.lex_markup_declaration();

        if (lexer.matches_at(start, "</")) {
            if (lexer.is_name_start(start +| 2)) return lexer.lex_close_tag_name();
        }

        if (lexer.is_name_start(start +| 1)) {
            lexer.advance(1);
            lexer.push(.angle_open, start, lexer.position);

            const name = lexer.lex_element_name();

            lexer.raw_pending = RawKind.of_element_name(lexer.name_bytes(name));
            lexer.mode = .tag;

            return;
        }

        lexer.advance(1);
        lexer.push(.text, start, lexer.position);
    }

    fn lex_close_tag_name(lexer: *Lexer) void {
        assert(lexer.position < lexer.length);
        assert(lexer.matches_at(lexer.position, "</"));

        const start = lexer.position;

        lexer.advance(2);
        lexer.push(.angle_open_slash, start, lexer.position);
        _ = lexer.lex_element_name();

        lexer.raw_pending = null;
        lexer.mode = .tag;
    }

    fn lex_delimited(lexer: *Lexer, open: Kind, close: Kind, closer: []const u8) Name {
        assert(lexer.byte_at(lexer.position) == '{');
        assert(close.is_token());
        assert(closer.len == 2);
        assert(open.is_token());

        const start = lexer.position;

        lexer.advance(2);
        lexer.push(open, start, lexer.position);

        var name: Name = .empty;
        var name_pending = open == .tag_open;

        while (lexer.position < lexer.length) {
            if (lexer.matches_at(lexer.position, closer)) {
                const close_start = lexer.position;

                lexer.advance(token.source_length(closer));
                lexer.push(close, close_start, lexer.position);

                return name;
            }

            if (lexer.dialect == .django) {
                const byte = lexer.byte_at(lexer.position) orelse unreachable;

                assert(!is_line_end(byte));
            }

            const scanned = lexer.lex_interior_token(closer, name_pending);

            if (name_pending) {
                if (!scanned.is_empty()) {
                    name = scanned;
                    name_pending = false;
                }
            }
        }

        assert(lexer.dialect == .html);

        return name;
    }

    fn lex_element_name(lexer: *Lexer) Name {
        assert(lexer.position <= lexer.length);

        const start = lexer.position;

        lexer.scan_while(is_name_byte);

        if (lexer.position == start) return .empty;

        const stop = lexer.position;

        lexer.push(.element_name, start, stop);

        assert(start < stop);

        return .{ .start = start, .stop = stop };
    }

    fn lex_interior_string(lexer: *Lexer, quote: u8, closer: []const u8) void {
        assert(lexer.byte_at(lexer.position) == quote);
        assert(quote == '"' or quote == '\'');
        assert(closer.len == 2);

        const start = lexer.position;

        lexer.advance(1);

        while (lexer.position < lexer.length) {
            const byte = lexer.byte_at(lexer.position) orelse break;
            if (byte == '\n') break;
            if (lexer.matches_at(lexer.position, closer)) break;

            if (byte == '\\') {
                lexer.advance(1);

                if (lexer.byte_at(lexer.position) == '\n') break;

                if (lexer.dialect == .django) {
                    if (lexer.matches_at(lexer.position, closer)) break;
                }

                lexer.advance(1);

                continue;
            }

            lexer.advance(1);

            if (byte == quote) break;
        }

        lexer.push(.string, start, lexer.position);
    }

    fn lex_interior_token(lexer: *Lexer, closer: []const u8, name_pending: bool) Name {
        assert(closer.len == 2);
        assert(lexer.position < lexer.length);

        const start = lexer.position;
        const byte = lexer.byte_at(start) orelse return .empty;

        if (lexer.dialect == .django) {
            if (lexer.python_space_at(start) > 0) {
                lexer.lex_python_whitespace();

                return .empty;
            }

            if (name_pending) return lexer.lex_tag_word(closer);
        }

        if (scan.is_ascii_whitespace(byte)) {
            assert(lexer.dialect == .html);

            lexer.lex_whitespace();

            return .empty;
        }

        if (interior_punctuation(byte)) |kind| {
            lexer.advance(1);
            lexer.push(kind, start, lexer.position);

            return .empty;
        }

        const quoted = byte == '"' or byte == '\'';

        if (quoted) {
            lexer.lex_interior_string(byte, closer);

            return .empty;
        }

        if (std.ascii.isDigit(byte)) {
            lexer.scan_while(is_number_byte);
            lexer.push(.number, start, lexer.position);

            return .empty;
        }

        const kind: Kind = if (name_pending) .tag_name else .identifier;

        lexer.scan_interior_run(closer);

        if (lexer.position == start) lexer.advance(1);

        const stop = lexer.position;

        lexer.push(kind, start, stop);

        assert(start < stop);

        return .{ .start = start, .stop = stop };
    }

    fn lex_markup_declaration(lexer: *Lexer) void {
        assert(lexer.byte_at(lexer.position) == '<');
        assert(lexer.position + 2 <= lexer.length);

        const start = lexer.position;

        lexer.advance(2);
        lexer.lex_declaration_rest(start);
    }

    fn lex_declaration_rest(lexer: *Lexer, start: u32) void {
        assert(start <= lexer.position);
        assert(lexer.position <= lexer.length);

        lexer.scan_while(continues_declaration);

        lexer.mode = .text;

        if (lexer.position < lexer.length) {
            if (lexer.byte_at(lexer.position) == '>') {
                lexer.advance(1);
            } else {
                assert(lexer.dialect == .django);
                assert(lexer.is_template_open(lexer.position));

                lexer.mode = .declaration;
            }
        }

        lexer.push(.doctype_text, start, lexer.position);

        assert(lexer.position > start);
    }

    fn lex_python_whitespace(lexer: *Lexer) void {
        assert(lexer.dialect == .django);
        assert(lexer.python_space_at(lexer.position) > 0);

        const start = lexer.position;

        while (lexer.position < lexer.length) {
            const length = lexer.python_space_at(lexer.position);
            if (length == 0) break;

            assert(!is_line_end(lexer.source[lexer.position]));

            lexer.advance(length);
        }

        assert(lexer.position > start);

        lexer.push(.whitespace, start, lexer.position);
    }

    fn lex_raw_body(lexer: *Lexer, opening: RawOpening) void {
        assert(lexer.dialect == .django);
        assert(opening.pair.end.len > 0);

        const start = lexer.position;
        const stop = lexer.raw_body_stop(opening);

        switch (opening.pair.body) {
            .markup => lexer.verbatim_stop = stop,
            .text => {
                lexer.position = stop;

                lexer.push(.verbatim_text, start, stop);
            },
        }
    }

    fn raw_body_stop(lexer: *const Lexer, opening: RawOpening) u32 {
        assert(lexer.dialect == .django);
        assert(opening.pair.end.len > 0);

        var position = lexer.position;
        var nested: ?RawOpening = null;

        while (position < lexer.length) {
            const stop = lexer.construct_stop(position) orelse {
                position += 1;

                continue;
            };

            if (lexer.matches_at(position, "{%")) {
                const content = lexer.tag_content(position, stop);

                if (nested) |held| {
                    if (raw_opening_ends(held, content)) nested = null;
                } else {
                    if (raw_opening_ends(opening, content)) break;

                    if (opening.pair.stage == .parser) {
                        nested = raw_opening_of(lexer.raw_text_tags, content, .lexer);
                    }
                }
            }

            position = stop;
        }

        assert(position <= lexer.length);
        assert(position >= lexer.position);

        return position;
    }

    fn lex_raw_body_opened(lexer: *Lexer, start: u32) void {
        assert(lexer.dialect == .django);
        assert(start < lexer.position);

        if (lexer.truncated) return;

        const content = lexer.tag_content(start, lexer.position);
        const opening = raw_opening_of(lexer.raw_text_tags, content, null) orelse return;

        lexer.lex_raw_body(opening);
    }

    fn lex_tag_punctuation(lexer: *Lexer, byte: u8) bool {
        assert(lexer.mode == .tag);
        assert(lexer.byte_at(lexer.position) == byte);

        if (lexer.dialect == .django) return lexer.lex_tag_punctuation_django(byte);

        const start = lexer.position;

        if (byte == '>') {
            lexer.advance(1);
            lexer.push(.angle_close, start, lexer.position);
            lexer.close_open_tag();

            return true;
        }

        if (byte == '/') {
            if (lexer.byte_ahead(start, 1) == '>') {
                lexer.advance(2);
                lexer.push(.slash_angle_close, start, lexer.position);

                lexer.raw_pending = null;
                lexer.mode = .text;
                lexer.after_equals = false;
                lexer.after_name = false;

                return true;
            }

            if (!lexer.after_equals) {
                lexer.advance(1);
                lexer.push(.slash, start, lexer.position);

                lexer.after_name = false;

                return true;
            }
        }

        if (byte == '=') {
            if (!lexer.after_name) return false;

            lexer.advance(1);
            lexer.push(.equals, start, lexer.position);

            lexer.after_equals = true;
            lexer.after_name = false;

            return true;
        }

        const quoted = byte == '"' or byte == '\'';

        if (lexer.after_equals) {
            if (quoted) {
                lexer.advance(1);
                lexer.push(.quote, start, lexer.position);

                lexer.mode = .{ .attribute_value = byte };

                return true;
            }
        }

        return false;
    }

    fn lex_tag_punctuation_django(lexer: *Lexer, byte: u8) bool {
        assert(lexer.dialect == .django);
        assert(lexer.byte_at(lexer.position) == byte);

        const start = lexer.position;

        switch (byte) {
            '>' => {
                lexer.advance(1);
                lexer.push(.angle_close, start, lexer.position);
                lexer.close_open_tag();
            },
            '/' => {
                if (lexer.after_equals) return false;
                if (lexer.value_unquoted) return false;

                if (lexer.byte_ahead(start, 1) != '>') {
                    lexer.advance(1);
                    lexer.push(.slash, start, lexer.position);

                    return true;
                }

                lexer.advance(2);
                lexer.push(.slash_angle_close, start, lexer.position);

                lexer.raw_pending = null;
                lexer.mode = .text;
                lexer.after_equals = false;
                lexer.value_unquoted = false;
            },
            '=' => {
                if (lexer.value_unquoted) return false;

                lexer.advance(1);
                lexer.push(.equals, start, lexer.position);

                lexer.after_equals = true;
            },
            '"', '\'' => {
                lexer.advance(1);
                lexer.push(.quote, start, lexer.position);

                lexer.mode = .{ .attribute_value = byte };
                lexer.value_unquoted = false;
            },
            else => return false,
        }

        return true;
    }

    fn lex_tag_run(lexer: *Lexer) void {
        assert(lexer.dialect == .django);
        assert(lexer.mode == .tag);

        const value = lexer.after_equals or lexer.value_unquoted;
        const start = lexer.position;

        if (value) {
            lexer.scan_while(continues_value_run);
            lexer.push(.attribute_text, start, lexer.position);
        } else {
            lexer.scan_while(continues_tag_run);
            lexer.push(.attribute_name, start, lexer.position);
        }

        lexer.value_continue(value);

        assert(lexer.position > start);
    }

    fn value_continue(lexer: *Lexer, value: bool) void {
        assert(lexer.dialect == .django);
        assert(lexer.mode == .tag);

        lexer.after_equals = false;
        lexer.value_unquoted = value;
    }

    fn lex_tag_word(lexer: *Lexer, closer: []const u8) Name {
        assert(lexer.dialect == .django);
        assert(lexer.python_space_at(lexer.position) == 0);
        assert(closer.len <= std.math.maxInt(u32));

        const start = lexer.position;

        while (lexer.position < lexer.length) {
            if (lexer.matches_at(lexer.position, closer)) break;
            if (lexer.python_space_at(lexer.position) > 0) break;

            lexer.advance(1);
        }

        assert(lexer.position > start);

        lexer.push(.tag_name, start, lexer.position);

        return .{ .start = start, .stop = lexer.position };
    }

    fn lex_template_comment(lexer: *Lexer) void {
        assert(lexer.position + 2 <= lexer.length);
        assert(lexer.matches_at(lexer.position, "{#"));

        const start = lexer.position;

        lexer.advance(2);
        lexer.push(.comment_open, start, lexer.position);

        const text_start = lexer.position;

        lexer.scan_while(continues_template_comment);
        lexer.push(.comment_text, text_start, lexer.position);

        if (lexer.dialect == .django) assert(lexer.matches_at(lexer.position, "#}"));

        if (lexer.matches_at(lexer.position, "#}")) {
            const close_start = lexer.position;

            lexer.advance(2);
            lexer.push(.comment_close, close_start, lexer.position);
        }
    }

    fn lex_template_construct(lexer: *Lexer) bool {
        assert(lexer.position < lexer.length);
        assert(!lexer.truncated);

        if (!lexer.is_template_open(lexer.position)) return false;

        if (lexer.verbatim_stop) |stop| assert(stop <= lexer.position);

        lexer.verbatim_stop = null;

        const next = lexer.byte_ahead(lexer.position, 1) orelse unreachable;

        switch (next) {
            '{' => _ = lexer.lex_delimited(.variable_open, .variable_close, "}}"),
            '%' => lexer.lex_template_tag(),
            '#' => lexer.lex_template_comment(),
            else => unreachable,
        }

        return true;
    }

    fn lex_template_tag(lexer: *Lexer) void {
        assert(lexer.matches_at(lexer.position, "{%"));

        const start = lexer.position;
        const name = lexer.lex_delimited(.tag_open, .tag_close, "%}");
        const text = lexer.name_bytes(name);

        assert(text.len <= lexer.length);

        if (lexer.dialect == .django) return lexer.lex_raw_body_opened(start);

        for (lexer.raw_text_tags) |pair| {
            if (std.mem.eql(u8, pair.name, text)) return lexer.lex_verbatim_body(pair);
        }
    }

    fn lex_verbatim_body(lexer: *Lexer, pair: RawTextTag) void {
        assert(pair.end.len > 0);
        assert(lexer.dialect == .html);

        const start = lexer.position;
        var stop = start;

        while (stop < lexer.length) {
            if (lexer.is_verbatim_end(stop, pair.end)) break;

            stop += 1;
        }

        assert(stop <= lexer.length);

        switch (pair.body) {
            .markup => lexer.verbatim_stop = stop,
            .text => {
                lexer.position = stop;

                lexer.push(.verbatim_text, start, stop);
            },
        }
    }

    fn lex_whitespace(lexer: *Lexer) void {
        assert(lexer.position < lexer.length);

        const start = lexer.position;

        lexer.scan_while(continues_whitespace);
        lexer.push(.whitespace, start, lexer.position);

        assert(lexer.position >= start);
    }

    fn scan_interior_run(lexer: *Lexer, closer: []const u8) void {
        assert(closer.len == 2);

        while (lexer.position < lexer.length) {
            if (lexer.is_interior_boundary(lexer.position, closer)) break;

            lexer.advance(1);
        }

        assert(lexer.position <= lexer.length);
    }

    fn scan_while(lexer: *Lexer, comptime keep: fn (*const Lexer, u32) bool) void {
        while (lexer.position < lexer.length) {
            if (!keep(lexer, lexer.position)) break;

            lexer.advance(1);
        }

        assert(lexer.position <= lexer.length);
    }

    fn push(lexer: *Lexer, kind: Kind, start: u32, stop: u32) void {
        assert(kind.is_token());
        assert(start <= stop);

        if (lexer.truncated) return;
        if (stop <= start) return;

        if (lexer.tokens.count() + 1 < lexer.tokens.capacity()) {
            lexer.tokens.push(kind, .between(start, stop)) catch unreachable;

            return;
        }

        lexer.truncated = true;
        lexer.position = lexer.length;
    }

    fn advance(lexer: *Lexer, step_count: u32) void {
        assert(step_count > 0);

        lexer.position = @min(lexer.position +| step_count, lexer.length);

        assert(lexer.position <= lexer.length);
    }

    fn close_open_tag(lexer: *Lexer) void {
        assert(lexer.position <= lexer.length);
        assert(lexer.mode == .tag);

        lexer.after_equals = false;
        lexer.after_name = false;
        lexer.value_unquoted = false;
        lexer.mode = if (lexer.raw_pending) |kind| .{ .raw_text = kind } else .text;
        lexer.raw_pending = null;
        lexer.script_escape = .none;
    }

    fn byte_ahead(lexer: *const Lexer, position: u32, offset: u32) ?u8 {
        assert(offset > 0);
        assert(lexer.length == lexer.source.len);
        assert(position < std.math.maxInt(u32));

        const target = std.math.add(u32, position, offset) catch return null;
        return lexer.byte_at(target);
    }

    fn byte_at(lexer: *const Lexer, position: u32) ?u8 {
        assert(lexer.position <= lexer.length);
        assert(lexer.length == lexer.source.len);

        if (position >= lexer.source.len) return null;
        return lexer.source[position];
    }

    fn matches_at(lexer: *const Lexer, position: u32, needle: []const u8) bool {
        assert(lexer.length == lexer.source.len);
        assert(needle.len > 0);
        assert(position < std.math.maxInt(u32));

        const start: usize = position;
        if (start + needle.len > lexer.source.len) return false;
        return std.mem.eql(u8, lexer.source[start..][0..needle.len], needle);
    }

    fn python_space_at(lexer: *const Lexer, position: u32) u32 {
        assert(lexer.dialect == .django);
        assert(position <= lexer.length);

        return python_space_prefix_length(lexer.source[position..]);
    }

    fn tag_content(lexer: *const Lexer, start: u32, stop: u32) []const u8 {
        assert(start + 4 <= stop);
        assert(lexer.matches_at(start, "{%"));
        assert(lexer.matches_at(stop - 2, "%}"));

        return trim_python(lexer.source[start + 2 .. stop - 2]);
    }

    fn name_bytes(lexer: *const Lexer, name: Name) []const u8 {
        assert(name.start <= lexer.length);
        assert(name.stop <= lexer.length);

        if (name.is_empty()) return "";
        return lexer.source[name.start..name.stop];
    }

    fn is_interior_boundary(lexer: *const Lexer, position: u32, closer: []const u8) bool {
        assert(lexer.position <= lexer.length);
        assert(closer.len == 2);

        const byte = lexer.byte_at(position) orelse return true;
        if (scan.is_ascii_whitespace(byte)) return true;

        if (lexer.dialect == .django) {
            if (lexer.python_space_at(position) > 0) return true;
        }

        if (byte == '"') return true;
        if (byte == '\'') return true;
        if (interior_punctuation(byte) != null) return true;
        return lexer.matches_at(position, closer);
    }

    fn is_name_byte(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(position < lexer.length);

        const byte = lexer.byte_at(position) orelse return false;
        if (scan.is_ascii_whitespace(byte)) return false;

        return switch (byte) {
            '/', '>', '=' => false,
            else => !lexer.is_template_open(position),
        };
    }

    fn is_name_start(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(lexer.length == lexer.source.len);

        const byte = lexer.byte_at(position) orelse return false;
        return std.ascii.isAlphabetic(byte);
    }

    fn is_number_byte(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(position < lexer.length);

        const byte = lexer.byte_at(position) orelse return false;
        if (std.ascii.isDigit(byte)) return true;
        if (byte != '.') return false;

        const next = lexer.byte_ahead(position, 1) orelse return false;
        return std.ascii.isDigit(next);
    }

    fn is_raw_text_end(lexer: *const Lexer, position: u32, kind: RawKind) bool {
        assert(lexer.mode == .raw_text);
        assert(position < lexer.length);

        if (kind != .script) assert(lexer.script_escape == .none);

        if (kind == .plaintext) return false;
        if (lexer.script_escape == .double) return false;
        return lexer.is_end_tag_at(position, kind.element_name());
    }

    fn is_end_tag_at(lexer: *const Lexer, position: u32, name: []const u8) bool {
        assert(name.len > 0);
        assert(position < lexer.length);

        if (!lexer.matches_at(position, "</")) return false;
        return lexer.is_name_delimited_at(position +| 2, name);
    }

    fn is_name_delimited_at(lexer: *const Lexer, position: u32, name: []const u8) bool {
        assert(name.len > 0);
        assert(lexer.length == lexer.source.len);
        assert(position < std.math.maxInt(u32));

        const start: usize = position;
        const end = start + name.len;
        if (end >= lexer.source.len) return false;
        if (!std.ascii.eqlIgnoreCase(lexer.source[start..end], name)) return false;

        return switch (lexer.source[end]) {
            '\t', '\n', 0x0c, '\r', ' ', '/', '>' => true,
            else => false,
        };
    }

    fn is_tag_run_boundary(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(position <= lexer.length);

        const byte = lexer.byte_at(position) orelse return true;
        if (scan.is_ascii_whitespace(byte)) return true;
        if (byte == '>') return true;

        if (byte == '/') {
            if (lexer.byte_ahead(position, 1) == '>') return true;
        }

        return lexer.is_template_open(position);
    }

    fn is_template_open(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(lexer.length == lexer.source.len);

        if (lexer.template_closer(position) == null) return false;

        if (lexer.verbatim_stop) |stop| {
            if (position < stop) return false;
        }

        if (lexer.dialect == .html) return true;
        return lexer.construct_stop(position) != null;
    }

    fn construct_stop(lexer: *const Lexer, position: u32) ?u32 {
        assert(lexer.dialect == .django);
        assert(position < lexer.length);

        const closer = lexer.template_closer(position) orelse return null;
        const start = position + 2;
        const stop = lexer.line_stop(start);
        const found = std.mem.find(u8, lexer.source[start..stop], closer) orelse return null;

        assert(found + 2 <= stop - start);

        return start + @as(u32, @intCast(found)) + 2;
    }

    fn line_stop(lexer: *const Lexer, start: u32) u32 {
        assert(lexer.dialect == .django);
        assert(start <= lexer.length);

        const found = std.mem.findAnyPos(u8, lexer.source, start, "\n\r");
        const stop = found orelse lexer.source.len;

        assert(stop >= start);

        return @intCast(stop);
    }

    fn template_closer(lexer: *const Lexer, position: u32) ?[]const u8 {
        assert(lexer.length == lexer.source.len);

        if (lexer.byte_at(position) != '{') return null;

        const next = lexer.byte_ahead(position, 1) orelse return null;

        return switch (next) {
            '{' => "}}",
            '%' => "%}",
            '#' => "#}",
            else => null,
        };
    }

    fn is_verbatim_end(lexer: *const Lexer, position: u32, end_name: []const u8) bool {
        assert(end_name.len > 0);
        assert(position < lexer.length);
        assert(lexer.dialect == .html);

        if (!lexer.matches_at(position, "{%")) return false;

        const start: usize = @as(usize, position) + 2;
        const stop = @min(start + verbatim_scan_bytes_max, lexer.source.len);
        if (start > stop) return false;

        const window = lexer.source[start..stop];
        const close = std.mem.find(u8, window, "%}") orelse return false;

        assert(close <= window.len);

        return std.mem.eql(u8, trim_ascii(window[0..close]), end_name);
    }

    fn continues_attribute_name(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(position < lexer.length);

        if (lexer.byte_at(position) == '/') return false;
        if (lexer.byte_at(position) == '=') return false;
        return !lexer.is_tag_run_boundary(position);
    }

    fn continues_comment_text(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(position < lexer.length);

        if (lexer.byte_at(position) == '-') return false;
        return !lexer.is_template_open(position);
    }

    fn continues_declaration(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(position < lexer.length);

        if (lexer.byte_at(position) == '>') return false;
        if (lexer.dialect == .html) return true;
        return !lexer.is_template_open(position);
    }

    fn continues_tag_run(lexer: *const Lexer, position: u32) bool {
        assert(lexer.dialect == .django);
        assert(position < lexer.length);

        const byte = lexer.byte_at(position) orelse return false;

        return switch (byte) {
            '/', '=', '"', '\'' => false,
            else => !lexer.is_tag_run_boundary(position),
        };
    }

    fn continues_value_run(lexer: *const Lexer, position: u32) bool {
        assert(lexer.dialect == .django);
        assert(position < lexer.length);

        const byte = lexer.byte_at(position) orelse return false;
        if (scan.is_ascii_whitespace(byte)) return false;

        return switch (byte) {
            '"', '\'', '>' => false,
            else => !lexer.is_template_open(position),
        };
    }

    fn continues_template_comment(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(position < lexer.length);

        return !lexer.matches_at(position, "#}");
    }

    fn continues_text(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(position < lexer.length);

        if (lexer.byte_at(position) == '<') return false;
        return !lexer.is_template_open(position);
    }

    fn continues_unquoted_value(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(position < lexer.length);

        return !lexer.is_tag_run_boundary(position);
    }

    fn continues_whitespace(lexer: *const Lexer, position: u32) bool {
        assert(lexer.position <= lexer.length);
        assert(position < lexer.length);

        const byte = lexer.byte_at(position) orelse return false;
        return scan.is_ascii_whitespace(byte);
    }
};

const Mode = union(enum) {
    attribute_value: u8,
    declaration,
    html_comment,
    raw_text: RawKind,
    tag,
    text,
};

const RawKind = enum {
    iframe,
    noembed,
    noframes,
    plaintext,
    script,
    style,
    textarea,
    title,
    xmp,

    fn element_name(kind: RawKind) []const u8 {
        const held: []const u8 = @tagName(kind);

        assert(held.len > 0);
        assert(of_element_name(held) == kind);

        return held;
    }

    fn of_element_name(name: []const u8) ?RawKind {
        assert(name.len <= std.math.maxInt(u32));

        for (std.enums.values(RawKind)) |kind| {
            if (std.ascii.eqlIgnoreCase(name, @tagName(kind))) return kind;
        }

        return null;
    }

    fn text_kind(kind: RawKind) Kind {
        const held: Kind = switch (kind) {
            .script => .script_text,
            .style => .style_text,
            .iframe, .noembed, .noframes, .plaintext, .textarea, .title, .xmp => .text,
        };

        assert(held.is_token());
        assert(held == .text or held.category() == .other);

        return held;
    }
};

const RawOpening = struct {
    arguments: []const u8,
    pair: RawTextTag,
};

const ScriptEscape = enum {
    none,
    escaped,
    double,
};

const Name = struct {
    start: u32,
    stop: u32,

    const empty: Name = .{ .start = 0, .stop = 0 };

    fn is_empty(name: Name) bool {
        return name.stop <= name.start;
    }
};

const verbatim_scan_bytes_max: u32 = 1_024;

const python_spaces = [_][]const u8{
    "\t",
    "\n",
    "\x0b",
    "\x0c",
    "\r",
    "\x1c",
    "\x1d",
    "\x1e",
    "\x1f",
    " ",
    "\u{85}",
    "\u{a0}",
    "\u{1680}",
    "\u{2000}",
    "\u{2001}",
    "\u{2002}",
    "\u{2003}",
    "\u{2004}",
    "\u{2005}",
    "\u{2006}",
    "\u{2007}",
    "\u{2008}",
    "\u{2009}",
    "\u{200a}",
    "\u{2028}",
    "\u{2029}",
    "\u{202f}",
    "\u{205f}",
    "\u{3000}",
};

pub fn lex(source: []const u8, tokens: *Tokens) error{Truncated}!void {
    assert(tokens.capacity() > 0);
    assert(source.len <= std.math.maxInt(u32));

    return lex_with(source, tokens, &.{});
}

pub fn lex_with(
    source: []const u8,
    tokens: *Tokens,
    raw_text_tags: []const RawTextTag,
) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(raw_text_tags.len <= std.math.maxInt(u32));

    return lex_dialect(source, tokens, raw_text_tags, .html);
}

pub fn lex_dialect(
    source: []const u8,
    tokens: *Tokens,
    raw_text_tags: []const RawTextTag,
    dialect: Dialect,
) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(raw_text_tags.len <= std.math.maxInt(u32));

    tokens.clear();

    var lexer: Lexer = .init(source, tokens, raw_text_tags, dialect);

    try lexer.run();

    assert(tokens.end_previous == source.len);
    assert(lexer.dialect == dialect);
}

fn interior_punctuation(byte: u8) ?Kind {
    return switch (byte) {
        '|' => .pipe,
        ':' => .colon,
        ',' => .comma,
        '.' => .dot,
        '=' => .equals,
        else => null,
    };
}

fn is_line_end(byte: u8) bool {
    if (byte > '\r') return false;

    const result = byte == '\n' or byte == '\r';

    if (result) assert(scan.is_ascii_whitespace(byte));

    return result;
}

fn python_space_prefix_length(text: []const u8) u32 {
    assert(text.len <= std.math.maxInt(u32));

    for (python_spaces) |space| {
        assert(space.len > 0);

        if (std.mem.startsWith(u8, text, space)) {
            assert(space.len <= text.len);

            return @intCast(space.len);
        }
    }

    return 0;
}

fn python_space_suffix_length(text: []const u8) u32 {
    assert(text.len <= std.math.maxInt(u32));

    for (python_spaces) |space| {
        assert(space.len > 0);

        if (std.mem.endsWith(u8, text, space)) {
            assert(space.len <= text.len);

            return @intCast(space.len);
        }
    }

    return 0;
}

fn raw_arguments_open(stage: RawTextTag.Stage, arguments: []const u8) bool {
    if (arguments.len == 0) return true;

    return switch (stage) {
        .lexer => arguments[0] == ' ',
        .parser => python_space_prefix_length(arguments) > 0,
    };
}

fn raw_opening_ends(opening: RawOpening, content: []const u8) bool {
    assert(opening.pair.end.len > 0);
    assert(raw_arguments_open(opening.pair.stage, opening.arguments));

    if (!std.mem.startsWith(u8, content, opening.pair.end)) return false;

    const rest = content[opening.pair.end.len..];

    return switch (opening.pair.stage) {
        .lexer => std.mem.eql(u8, rest, opening.arguments),
        .parser => rest.len == 0,
    };
}

pub fn raw_body_opened(raw_text_tags: []const RawTextTag, construct: []const u8) ?RawTextTag.Body {
    if (construct.len < 4) return null;
    if (!std.mem.startsWith(u8, construct, "{%")) return null;
    if (!std.mem.endsWith(u8, construct, "%}")) return null;
    assert(raw_text_tags.len <= std.math.maxInt(u32));

    const content = trim_python(construct[2 .. construct.len - 2]);
    const opening = raw_opening_of(raw_text_tags, content, null) orelse return null;

    assert(opening.pair.end.len > 0);
    assert(content.len >= opening.pair.name.len);

    return opening.pair.body;
}

fn raw_opening_of(
    pairs: []const RawTextTag,
    content: []const u8,
    stage: ?RawTextTag.Stage,
) ?RawOpening {
    assert(pairs.len <= std.math.maxInt(u32));
    assert(content.len <= std.math.maxInt(u32));
    if (stage) |wanted| assert(wanted == .lexer);

    for (pairs) |pair| {
        assert(pair.name.len > 0);
        assert(pair.end.len > 0);

        if (stage) |wanted| {
            if (pair.stage != wanted) continue;
        }

        if (!std.mem.startsWith(u8, content, pair.name)) continue;

        const arguments = content[pair.name.len..];

        if (raw_arguments_open(pair.stage, arguments)) {
            return .{ .arguments = arguments, .pair = pair };
        }
    }

    return null;
}

fn trim_python(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    var start: usize = 0;
    var stop: usize = text.len;

    for (0..text.len) |_| {
        const length = python_space_prefix_length(text[start..stop]);
        if (length == 0) break;

        start += length;
    }

    for (0..text.len) |_| {
        const length = python_space_suffix_length(text[start..stop]);
        if (length == 0) break;

        stop -= length;
    }

    assert(start <= stop);
    assert(stop <= text.len);

    return text[start..stop];
}

fn trim_ascii(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    var start: usize = 0;
    var stop: usize = text.len;

    while (start < stop) {
        if (!scan.is_ascii_whitespace(text[start])) break;

        start += 1;
    }

    while (stop > start) {
        if (!scan.is_ascii_whitespace(text[stop - 1])) break;

        stop -= 1;
    }

    assert(start <= stop);
    assert(stop <= text.len);

    return text[start..stop];
}

const raw_text_tags_test = [_]RawTextTag{
    .{ .body = .text, .end = "endcomment", .name = "comment", .stage = .parser },
    .{ .body = .text, .end = "endverbatim", .name = "verbatim", .stage = .lexer },
};

fn kinds_lexed(
    gpa: std.mem.Allocator,
    source: []const u8,
    raw_text_tags: []const RawTextTag,
) !std.ArrayList(Kind) {
    assert(source.len <= std.math.maxInt(u32));
    assert(raw_text_tags.len <= std.math.maxInt(u32));

    var tokens: Tokens = try .init(gpa, 1 << 8);
    defer tokens.deinit(gpa);

    try lex_with(source, &tokens, raw_text_tags);

    var found: std.ArrayList(Kind) = .empty;
    errdefer found.deinit(gpa);

    for (tokens.slice()) |held| try found.append(gpa, held.kind);

    assert(found.items.len == tokens.count());

    return found;
}

fn kinds_count(kinds: []const Kind, wanted: Kind) u32 {
    assert(kinds.len <= std.math.maxInt(u32));
    assert(wanted.is_token());

    var held: u32 = 0;

    for (kinds) |kind| {
        if (kind == wanted) held += 1;
    }

    assert(held <= kinds.len);

    return held;
}

test "a named raw text tag swallows its body" {
    const gpa = std.testing.allocator;
    const source = "{% verbatim %}{{ a }}{% endverbatim %}";
    var found = try kinds_lexed(gpa, source, &raw_text_tags_test);
    defer found.deinit(gpa);

    try std.testing.expect(kinds_count(found.items, .verbatim_text) > 0);
    try std.testing.expect(kinds_count(found.items, .variable_open) == 0);
}

test "a body without a named pair lexes as template text" {
    const gpa = std.testing.allocator;
    const source = "{% verbatim %}{{ a }}{% endverbatim %}";
    var found = try kinds_lexed(gpa, source, &.{});
    defer found.deinit(gpa);

    try std.testing.expect(kinds_count(found.items, .verbatim_text) == 0);
    try std.testing.expect(kinds_count(found.items, .variable_open) > 0);
}

test "a raw body opens exactly where the Django lexer opens one" {
    const gpa = std.testing.allocator;

    const pairs = [_]RawTextTag{
        .{ .body = .text, .end = "endcomment", .name = "comment", .stage = .parser },
        .{ .body = .markup, .end = "endverbatim", .name = "verbatim", .stage = .lexer },
    };

    const cases = [_]struct { ?RawTextTag.Body, []const u8 }{
        .{ .markup, "{% verbatim %}" },
        .{ .markup, "{% verbatim x %}" },
        .{ .markup, "{%verbatim%}" },
        .{ .markup, "{% verbatim  x %}" },
        .{ null, "{% verbatim\tx %}" },
        .{ null, "{% verbatimx %}" },
        .{ null, "{% endverbatim %}" },
        .{ .text, "{% comment %}" },
        .{ .text, "{% comment \"n\" %}" },
        .{ .text, "{%\u{a0}comment\u{a0}%}" },
        .{ .text, "{% comment\tn %}" },
        .{ null, "{% commentary %}" },
        .{ null, "{% if a %}" },
        .{ null, "{{ a }}" },
        .{ null, "{%%}" },
    };

    for (cases) |case| {
        var tokens: Tokens = try .init(gpa, 1 << 6);
        defer tokens.deinit(gpa);

        var buffer: [64]u8 = undefined;
        const source = try std.mem.print(&buffer, "{s}{{{{ b }}}}", .{case[1]});

        try lex_dialect(source, &tokens, &pairs, .django);

        var variables: u32 = 0;

        for (tokens.slice()) |held| {
            if (held.kind == .variable_open) variables += 1;
        }

        const opened = raw_body_opened(&pairs, case[1]);
        const constructs: u32 = if (std.mem.startsWith(u8, case[1], "{{")) 2 else 1;

        try std.testing.expectEqual(case[0], opened);
        try std.testing.expectEqual(if (opened == null) constructs else constructs - 1, variables);
    }
}

test "each pair closes on its own end name" {
    const gpa = std.testing.allocator;

    const pairs = [_]RawTextTag{
        .{ .body = .text, .end = "endraw", .name = "raw", .stage = .lexer },
        .{ .body = .text, .end = "endverbatim", .name = "verbatim", .stage = .lexer },
    };

    var found = try kinds_lexed(gpa, "{% raw %}{% endverbatim %}{% endraw %}", &pairs);
    defer found.deinit(gpa);

    try std.testing.expectEqual(1, kinds_count(found.items, .verbatim_text));
    try std.testing.expectEqual(2, kinds_count(found.items, .tag_open));
}

test "a solidus inside a tag is a token of its own" {
    const gpa = std.testing.allocator;
    var found = try kinds_lexed(gpa, "<a/b c//d/>", &.{});
    defer found.deinit(gpa);

    const wanted = [_]Kind{
        .angle_open,
        .element_name,
        .slash,
        .attribute_name,
        .whitespace,
        .attribute_name,
        .slash,
        .slash,
        .attribute_name,
        .slash_angle_close,
    };

    try std.testing.expectEqualSlices(Kind, &wanted, found.items);
}

test "an unquoted value keeps its solidus" {
    const gpa = std.testing.allocator;
    var found = try kinds_lexed(gpa, "<a href=/x/y>", &.{});
    defer found.deinit(gpa);

    const wanted = [_]Kind{
        .angle_open,
        .element_name,
        .whitespace,
        .attribute_name,
        .equals,
        .attribute_text,
        .angle_close,
    };

    try std.testing.expectEqualSlices(Kind, &wanted, found.items);
}

test "a raw text element holds no markup" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "<title>a <b>c</b></title><p>",
        "<textarea><div></textarea><p>",
        "<xmp><!-- a --></xmp><p>",
        "<IFRAME><i></iframe><p>",
    };

    for (sources) |source| {
        var found = try kinds_lexed(gpa, source, &.{});
        defer found.deinit(gpa);

        try std.testing.expectEqual(3, kinds_count(found.items, .element_name));
        try std.testing.expectEqual(1, kinds_count(found.items, .angle_open_slash));
        try std.testing.expectEqual(0, kinds_count(found.items, .html_comment_open));
    }
}

test "a plaintext element runs to the end of the source" {
    const gpa = std.testing.allocator;
    var found = try kinds_lexed(gpa, "<plaintext><p>a</plaintext>b", &.{});
    defer found.deinit(gpa);

    try std.testing.expectEqual(1, kinds_count(found.items, .element_name));
    try std.testing.expectEqual(0, kinds_count(found.items, .angle_open_slash));
    try std.testing.expectEqual(Kind.text, found.items[found.items.len - 1]);
}

test "an escape inside a template string stops at the line end" {
    const gpa = std.testing.allocator;
    var spaced = try kinds_lexed(gpa, "{{ 'a\\\t\nb' }}", &.{});
    defer spaced.deinit(gpa);

    var trimmed = try kinds_lexed(gpa, "{{ 'a\\\nb' }}", &.{});
    defer trimmed.deinit(gpa);

    const wanted = [_]Kind{
        .variable_open,
        .whitespace,
        .string,
        .whitespace,
        .identifier,
        .string,
        .variable_close,
    };

    try std.testing.expectEqualSlices(Kind, &wanted, spaced.items);
    try std.testing.expectEqualSlices(Kind, &wanted, trimmed.items);
}

test "an equals sign separates a value only after a name" {
    const gpa = std.testing.allocator;
    var found = try kinds_lexed(gpa, "<a =\"v\" =x b = = c>", &.{});
    defer found.deinit(gpa);

    const wanted = [_]Kind{
        .angle_open,
        .element_name,
        .whitespace,
        .attribute_name,
        .whitespace,
        .equals,
        .attribute_text,
        .whitespace,
        .attribute_name,
        .whitespace,
        .equals,
        .whitespace,
        .attribute_text,
        .whitespace,
        .attribute_name,
        .angle_close,
    };

    try std.testing.expectEqualSlices(Kind, &wanted, found.items);
}

test "an unquoted value runs through its equals signs" {
    const gpa = std.testing.allocator;
    var found = try kinds_lexed(gpa, "<a href=x?a=b&c=d id='e'=f>", &.{});
    defer found.deinit(gpa);

    const wanted = [_]Kind{
        .angle_open,
        .element_name,
        .whitespace,
        .attribute_name,
        .equals,
        .attribute_text,
        .whitespace,
        .attribute_name,
        .equals,
        .quote,
        .attribute_text,
        .quote,
        .attribute_name,
        .angle_close,
    };

    try std.testing.expectEqualSlices(Kind, &wanted, found.items);
}

fn kinds_lexed_django(gpa: std.mem.Allocator, source: []const u8) !std.ArrayList(Kind) {
    assert(source.len <= std.math.maxInt(u32));

    var tokens: Tokens = try .init(gpa, 1 << 8);
    defer tokens.deinit(gpa);

    try lex_dialect(source, &tokens, &raw_text_tags_test, .django);

    var found: std.ArrayList(Kind) = .empty;
    errdefer found.deinit(gpa);

    for (tokens.slice()) |held| try found.append(gpa, held.kind);

    assert(found.items.len == tokens.count());
    assert(tokens.end_previous == source.len);

    return found;
}

test "the Django dialect ends an attribute name at a solidus the way HTML does" {
    const gpa = std.testing.allocator;
    var found = try kinds_lexed_django(gpa, "<a/b c//d/>");
    defer found.deinit(gpa);

    const wanted = [_]Kind{
        .angle_open,
        .element_name,
        .slash,
        .attribute_name,
        .whitespace,
        .attribute_name,
        .slash,
        .slash,
        .attribute_name,
        .slash_angle_close,
    };

    try std.testing.expectEqualSlices(Kind, &wanted, found.items);
}

test "the Django dialect splits a tag run at every quote and at an equals sign outside a value" {
    const gpa = std.testing.allocator;
    var found = try kinds_lexed_django(gpa, "<a href=x?a=b id='e'=f \"g\">");
    defer found.deinit(gpa);

    const wanted = [_]Kind{
        .angle_open,
        .element_name,
        .whitespace,
        .attribute_name,
        .equals,
        .attribute_text,
        .whitespace,
        .attribute_name,
        .equals,
        .quote,
        .attribute_text,
        .quote,
        .equals,
        .attribute_text,
        .whitespace,
        .quote,
        .attribute_text,
        .quote,
        .angle_close,
    };

    try std.testing.expectEqualSlices(Kind, &wanted, found.items);
}

fn raw_content_lexed(
    gpa: std.mem.Allocator,
    source: []const u8,
    dialect: Dialect,
) ![]const u8 {
    assert(source.len <= std.math.maxInt(u32));

    var tokens: Tokens = try .init(gpa, 1 << 8);
    defer tokens.deinit(gpa);

    try lex_dialect(source, &tokens, &.{}, dialect);

    var start: ?u32 = null;

    for (tokens.slice()) |held| {
        const opened = start orelse {
            if (held.kind == .angle_close) start = held.end();

            continue;
        };

        if (held.kind == .angle_open_slash) return source[opened..held.offset];
    }

    const opened = start orelse return error.TestUnexpectedResult;
    return source[opened..];
}

test "a raw text element ends where the HTML tokenizer of parse5 ends it" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "<title>a <b>c</b></title><p>", "a <b>c</b>" },
        .{ "<textarea><div></textarea><p>", "<div>" },
        .{ "<xmp><!-- a --></xmp><p>", "<!-- a -->" },
        .{ "<IFRAME><i></iframe><p>", "<i>" },
        .{ "<noembed><b></noembed><p>", "<b>" },
        .{ "<noframes><b></noframes><p>", "<b>" },
        .{ "<plaintext><p>a</p></plaintext><b>", "<p>a</p></plaintext><b>" },
        .{ "<script>a</scripts>b</script><p>c</p>", "a</scripts>b" },
        .{ "<textarea>a</textareax>b</textarea><p>c</p>", "a</textareax>b" },
        .{ "<title>a</title/><p>c</p>", "a" },
        .{ "<SCRIPT>a</Script >b", "a" },
        .{ "<script>a</script", "a</script" },
        .{ "<style><!-- </style> --></style><p>", "<!-- " },
        .{ "<textarea><!-- </textarea> --></textarea><p>", "<!-- " },
        .{ "<script><!-- <script> </script> --></script><p>c</p>", "<!-- <script> </script> -->" },
        .{ "<script><!-- <script> </script> </script><p>c</p>", "<!-- <script> </script> " },
        .{ "<script><!--> </script><p>c</p>", "<!--> " },
        .{ "<script><!-- --> </script><p>c</p>", "<!-- --> " },
        .{ "<script><!-- <scriptx> </script><p>c</p>", "<!-- <scriptx> " },
        .{
            "<script><!-- <script/> </script --> </script><p>c</p>",
            "<!-- <script/> </script --> ",
        },
        .{ "<script><!--<script>--></script><p>", "<!--<script>-->" },
        .{ "<script><!-- <SCRIPT\n></script> --></script><p>", "<!-- <SCRIPT\n></script> -->" },
        .{ "<script><!-- <script</script><p>", "<!-- <script" },
        .{ "<script><!---></script><p>", "<!--->" },
        .{ "<script><!-- -></script><p>", "<!-- ->" },
        .{ "<script><!- -></script><p>", "<!- ->" },
    };

    for (cases) |case| {
        for ([_]Dialect{ .html, .django }) |dialect| {
            const content = try raw_content_lexed(gpa, case[0], dialect);

            try std.testing.expectEqualStrings(case[1], content);
        }
    }
}

test "the Django dialect ends a string at the closer as Django does" {
    const gpa = std.testing.allocator;
    var found = try kinds_lexed_django(gpa, "{{ 'a }} b\nc");
    defer found.deinit(gpa);

    var escaped = try kinds_lexed_django(gpa, "{{ 'a\\}} b' }}");
    defer escaped.deinit(gpa);

    var split = try kinds_lexed_django(gpa, "{{ 'a\\\nb' }}");
    defer split.deinit(gpa);

    const wanted = [_]Kind{ .variable_open, .whitespace, .string, .variable_close, .text };

    try std.testing.expectEqualSlices(Kind, &wanted, found.items);
    try std.testing.expectEqualSlices(Kind, &wanted, escaped.items);
    try std.testing.expectEqualSlices(Kind, &.{.text}, split.items);
}

test "the Django dialect lexes a construct inside a declaration" {
    const gpa = std.testing.allocator;
    var split = try kinds_lexed_django(gpa, "<!x{% a %}y>z");
    defer split.deinit(gpa);

    var unclosed = try kinds_lexed_django(gpa, "<!x{% a\n%}y>z");
    defer unclosed.deinit(gpa);

    var html = try kinds_lexed(gpa, "<!x{% a %}y>z", &.{});
    defer html.deinit(gpa);

    try std.testing.expectEqualSlices(Kind, &.{
        .doctype_text,
        .tag_open,
        .whitespace,
        .tag_name,
        .whitespace,
        .tag_close,
        .doctype_text,
        .text,
    }, split.items);

    try std.testing.expectEqualSlices(Kind, &.{ .doctype_text, .text }, unclosed.items);
    try std.testing.expectEqualSlices(Kind, &.{ .doctype_text, .text }, html.items);
}

test "the Django dialect reads an opener that does not close on its line as text" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { source: []const u8, wanted: []const Kind }{
        .{ .source = "{% include 'a.html'\n    with x=1 %}", .wanted = &.{.text} },
        .{ .source = "{#\n    note\n#}", .wanted = &.{.text} },
        .{ .source = "{{ a\n}}", .wanted = &.{.text} },
        .{
            .source = "{{% block a %}",
            .wanted = &.{
                .text,
                .tag_open,
                .whitespace,
                .tag_name,
                .whitespace,
                .identifier,
                .whitespace,
                .tag_close,
            },
        },
        .{
            .source = "<p title=\"{% if a\n%}\">{{ b }}</p>",
            .wanted = &.{
                .angle_open,
                .element_name,
                .whitespace,
                .attribute_name,
                .equals,
                .quote,
                .attribute_text,
                .quote,
                .angle_close,
                .variable_open,
                .whitespace,
                .identifier,
                .whitespace,
                .variable_close,
                .angle_open_slash,
                .element_name,
                .angle_close,
            },
        },
        .{
            .source = "{% verbatim %}a{%\nendverbatim %}{% endverbatim %}",
            .wanted = &.{
                .tag_open,
                .whitespace,
                .tag_name,
                .whitespace,
                .tag_close,
                .verbatim_text,
                .tag_open,
                .whitespace,
                .tag_name,
                .whitespace,
                .tag_close,
            },
        },
    };

    for (cases) |case| {
        var found = try kinds_lexed_django(gpa, case.source);
        defer found.deinit(gpa);

        try std.testing.expectEqualSlices(Kind, case.wanted, found.items);
    }
}

const Construct = struct {
    kind: Kind,
    start: u32,
    stop: u32,
};

fn constructs_lexed_django(
    gpa: std.mem.Allocator,
    source: []const u8,
) !std.ArrayList(Construct) {
    assert(source.len <= std.math.maxInt(u32));

    var tokens: Tokens = try .init(gpa, 1 << 8);
    defer tokens.deinit(gpa);

    try lex_dialect(source, &tokens, &raw_text_tags_test, .django);

    var found: std.ArrayList(Construct) = .empty;
    errdefer found.deinit(gpa);

    var start: ?u32 = null;

    for (tokens.slice()) |held| {
        switch (held.kind) {
            .comment_open, .tag_open, .variable_open => start = held.offset,
            .comment_close, .tag_close, .variable_close => {
                const opened = start orelse unreachable;

                try found.append(gpa, .{ .kind = held.kind, .start = opened, .stop = held.end() });

                start = null;
            },
            .verbatim_text => try found.append(gpa, construct_raw(held.offset, held.end())),
            else => {},
        }
    }

    assert(start == null);
    assert(found.items.len <= tokens.count());

    return found;
}

fn construct_raw(start: u32, stop: u32) Construct {
    assert(start < std.math.maxInt(u32));
    assert(stop < std.math.maxInt(u32));

    return .{ .kind = .verbatim_text, .start = start, .stop = stop };
}

fn construct_tag(start: u32, stop: u32) Construct {
    assert(start < std.math.maxInt(u32));
    assert(stop < std.math.maxInt(u32));

    return .{ .kind = .tag_close, .start = start, .stop = stop };
}

fn construct_variable(start: u32, stop: u32) Construct {
    assert(start < std.math.maxInt(u32));
    assert(stop < std.math.maxInt(u32));

    return .{ .kind = .variable_close, .start = start, .stop = stop };
}

test "the Django dialect finds the constructs and raw bodies that Django finds" {
    const gpa = std.testing.allocator;
    const raw = construct_raw;
    const tag = construct_tag;
    const variable = construct_variable;

    const cases = [_]struct { source: []const u8, wanted: []const Construct }{
        .{ .source = "a\r{{ b }}\r{{ c\r}}", .wanted = &.{variable(2, 9)} },
        .{
            .source = "{% verbatim x %}{% endverbatim %}{% endverbatim x %}",
            .wanted = &.{ tag(0, 16), raw(16, 33), tag(33, 52) },
        },
        .{
            .source = "{% verbatim\tx %}{{ a }}{% endverbatim %}",
            .wanted = &.{ tag(0, 16), variable(16, 23), tag(23, 40) },
        },
        .{
            .source = "{% comment %}{{ '{% endcomment %}' }}{% endcomment %}",
            .wanted = &.{ tag(0, 13), raw(13, 37), tag(37, 53) },
        },
        .{
            .source = "{% comment %}{% verbatim %}{% endcomment %}" ++
                "{% endverbatim %}{% endcomment %}",
            .wanted = &.{ tag(0, 13), raw(13, 60), tag(60, 76) },
        },
        .{
            .source = "{%\u{a0}comment\u{a0}%}x{%\u{a0}endcomment\u{a0}%}",
            .wanted = &.{ tag(0, 15), raw(15, 16), tag(16, 34) },
        },
        .{
            .source = "{% comment \"note\" %}x{% endcomment %}",
            .wanted = &.{ tag(0, 20), raw(20, 21), tag(21, 37) },
        },
        .{
            .source = "{% comment %}x{% endcomment y %}z{% endcomment %}",
            .wanted = &.{ tag(0, 13), raw(13, 33), tag(33, 49) },
        },
        .{
            .source = "{% verbatim %}{%x{% endverbatim %}y{% endverbatim %}",
            .wanted = &.{ tag(0, 14), raw(14, 35), tag(35, 52) },
        },
        .{
            .source = "{% verbatim  x %}a{% endverbatim x %}b{% endverbatim  x %}",
            .wanted = &.{ tag(0, 17), raw(17, 38), tag(38, 58) },
        },
        .{
            .source = "{% commentary %}{{ a }}{% endcommentary %}",
            .wanted = &.{ tag(0, 16), variable(16, 23), tag(23, 42) },
        },
    };

    for (cases) |case| {
        var found = try constructs_lexed_django(gpa, case.source);
        defer found.deinit(gpa);

        try std.testing.expectEqualSlices(Construct, case.wanted, found.items);
    }
}

test "the Django dialect names a tag by its first word as Django does" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { source: []const u8, wanted: []const u8 }{
        .{ .source = "{% if\"x\" %}", .wanted = "if\"x\"" },
        .{ .source = "{%\u{a0}if\u{a0}x\u{a0}%}", .wanted = "if" },
        .{ .source = "{% 'a' if %}", .wanted = "'a'" },
        .{ .source = "{% load\u{3000}static %}", .wanted = "load" },
        .{ .source = "{%\x0bwith\x1ca=1 %}", .wanted = "with" },
        .{ .source = "{% url|x %}", .wanted = "url|x" },
    };

    for (cases) |case| {
        var tokens: Tokens = try .init(gpa, 1 << 8);
        defer tokens.deinit(gpa);

        try lex_dialect(case.source, &tokens, &raw_text_tags_test, .django);

        var names: u32 = 0;

        for (tokens.slice()) |held| {
            if (held.kind != .tag_name) continue;

            names += 1;

            try std.testing.expectEqualStrings(case.wanted, held.text(case.source));
        }

        try std.testing.expectEqual(1, names);
    }
}
