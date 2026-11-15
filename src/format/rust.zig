const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const FormatterError = @import("formatters.zig").FormatterError;
pub const Kind = @import("../syntax/rust/kind.zig").Kind;
const Options = @import("print.zig").Options;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Terminators = @import("mask.zig").Terminators;
const Token = @import("../syntax/token.zig");
const Tree = @import("../syntax/tree.zig").TreeType(Kind);
const alignment = @import("align.zig");
const ascii_whitespace = @import("../text/scan.zig").ascii_whitespace;
const brace = @import("brace.zig");
const front_skip = @import("../syntax/rust/lex.zig").front_skip;
const is_ascii_whitespace = @import("../text/scan.zig").is_ascii_whitespace;
const is_identifier_part = @import("../text/scan.zig").is_identifier_part;
const trim_ascii = @import("../text/scan.zig").trim_ascii;
const walk = @import("walk.zig");
const word_in = @import("../text/scan.zig").word_in;

pub const Formatter = struct {
    gives: ArrayType(u32),
    inner: brace.Formatter,
    keys: Buffer,
    lines: ArrayType(u32),
    macros: ArrayType(u32),
    opaques: ArrayType(u32),
    scratch: Buffer,
    staged: Buffer,
    stream: Terminators,
    uses: Buffer,

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        scratch_bytes_max: u32,
    ) std.mem.Allocator.Error!Formatter {
        assert(element_count_max > 0);
        assert(scratch_bytes_max > 0);

        var gives = try ArrayType(u32).init(gpa, give_marks_max);
        errdefer gives.deinit(gpa);

        var inner = try brace.Formatter.init(gpa, element_count_max, scratch_bytes_max);
        errdefer inner.deinit(gpa);

        var keys = try Buffer.init(gpa, use_bytes_max);
        errdefer keys.deinit(gpa);

        var lines = try ArrayType(u32).init(gpa, element_count_max);
        errdefer lines.deinit(gpa);

        var macros = try ArrayType(u32).init(gpa, give_marks_max);
        errdefer macros.deinit(gpa);

        var opaques = try ArrayType(u32).init(gpa, give_marks_max);
        errdefer opaques.deinit(gpa);

        var scratch = try Buffer.init(gpa, scratch_bytes_max);
        errdefer scratch.deinit(gpa);

        var staged = try Buffer.init(gpa, scratch_bytes_max);
        errdefer staged.deinit(gpa);

        var stream = try Terminators.init(gpa, element_count_max, scratch_bytes_max);
        errdefer stream.deinit(gpa);

        const uses = try Buffer.init(gpa, use_bytes_max);

        return .{
            .gives = gives,
            .inner = inner,
            .keys = keys,
            .lines = lines,
            .macros = macros,
            .opaques = opaques,
            .scratch = scratch,
            .staged = staged,
            .stream = stream,
            .uses = uses,
        };
    }

    pub fn deinit(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.gives.capacity() == give_marks_max);
        assert(formatter.macros.capacity() == give_marks_max);
        assert(formatter.opaques.capacity() == give_marks_max);

        formatter.uses.deinit(gpa);
        formatter.stream.deinit(gpa);
        formatter.staged.deinit(gpa);
        formatter.scratch.deinit(gpa);
        formatter.opaques.deinit(gpa);
        formatter.macros.deinit(gpa);
        formatter.lines.deinit(gpa);
        formatter.keys.deinit(gpa);
        formatter.inner.deinit(gpa);
        formatter.gives.deinit(gpa);
        formatter.* = undefined;
    }

    pub fn format(formatter: *Formatter, input: *const Input, out: *Buffer) FormatterError!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        if (broken(input)) return error.SourceInvalid;
        if (skipped_file(input.source)) return copied(input.source, out);
        if (input.tokens.len == 0) return blanked(out);

        const widths: brace.Widths = .{
            .indent = input.options.indent_width,
            .line = input.options.line_width,
        };

        brace.tailed(
            Kind,
            input.tree,
            input.source,
            input.tokens,
            &tails,
            widths,
            &formatter.stream,
        ) catch return error.OutputExhausted;

        const stream = &formatter.stream;

        const held: brace.Input = .{
            .added = stream.added_slice(),
            .gives = &.{},
            .lists = stream.lists_slice(),
            .macros = &.{},
            .marks = &.{},
            .nests = &.{},
            .opaques = &.{},
            .operand_ends = &.{},
            .operands = &.{},
            .options = input.options,
            .origin = input.source,
            .origins = stream.origins_slice(),
            .policy = policy,
            .roles = stream.roles_slice(),
            .source = stream.source_slice(),
            .tokens = stream.tokens_slice(),
        };

        formatter.printing(&held, input.options.line_width) catch return error.OutputExhausted;
        formatter.aligned(input.options.line_width) catch return error.OutputExhausted;
        formatter.sorted(widths) catch return error.OutputExhausted;

        const normal = formatter.normalized() catch return error.OutputExhausted;

        out.clear();

        reordered(normal, out) catch {
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

    fn printing(formatter: *Formatter, held: *const brace.Input, width: u32) error{Overflow}!void {
        assert(held.tokens.len == held.roles.len);
        assert(width > 0);

        formatter.gives.clear();
        formatter.macros.clear();
        formatter.opaques.clear();

        _ = comments(held.source, held.tokens, &formatter.gives);
        _ = patterned(held.source, held.tokens, &formatter.gives);
        _ = spilled(held.source, held.tokens, width, &formatter.gives);

        _ = give_macros(
            held.source,
            held.tokens,
            &formatter.gives,
            &formatter.macros,
            &formatter.opaques,
        );

        const widths: brace.Widths = .{ .indent = held.options.indent_width, .line = width };

        for (0..give_passes) |_| {
            var round = held.*;

            round.gives = formatter.gives.const_slice();
            round.macros = formatter.macros.const_slice();
            round.nests = &.{};
            round.opaques = formatter.opaques.const_slice();

            try formatter.inner.formatting(&round, &formatter.scratch, &formatter.lines);

            const marked = marks(
                held.source,
                held.tokens,
                formatter.scratch.const_slice(),
                formatter.lines.const_slice(),
                widths,
                &formatter.gives,
            );

            if (!marked) break;
        }

        assert(formatter.macros.count() <= formatter.gives.count());
    }

    fn aligned(formatter: *Formatter, line_width: u32) error{Overflow}!void {
        assert(line_width > 0);
        assert(formatter.scratch.count() <= formatter.staged.capacity());

        const scratch = formatter.scratch.const_slice();

        try alignment.@"align"(scratch, .element, line_width, &formatter.staged);
    }

    fn sorted(formatter: *Formatter, widths: brace.Widths) error{Overflow}!void {
        assert(widths.line > 0);
        assert(formatter.staged.count() <= formatter.scratch.capacity());

        const bytes = formatter.staged.const_slice();
        const front = front_skip(bytes);
        var reading: Reading = .initial;
        var invocation: Invocation = .outside;
        var offset: u32 = front;

        formatter.scratch.clear();
        try formatter.scratch.push(bytes[0..front]);

        while (offset < bytes.len) {
            const stop = try formatter.sorted_step(bytes, offset, &reading, &invocation, widths);

            assert(stop > offset);
            assert(stop <= bytes.len);

            offset = stop;
        }

        assert(formatter.scratch.count() <= formatter.scratch.capacity());
    }

    fn sorted_step(
        formatter: *Formatter,
        bytes: []const u8,
        offset: u32,
        reading: *Reading,
        invocation: *Invocation,
        widths: brace.Widths,
    ) error{Overflow}!u32 {
        assert(offset < bytes.len);
        assert(widths.line > 0);

        const out = &formatter.scratch;
        const inside = reading.verbatim() or invocation.inside != null;
        const past = if (inside) null else skipping(bytes, offset);

        if (past) |stop| {
            const end = @min(stop, @as(u32, @intCast(bytes.len)));

            try out.push(bytes[offset..end]);
            invoked_stepping(bytes, offset, end, reading, invocation);

            assert(end <= bytes.len);

            return end;
        }

        const import = if (inside) null else imported(bytes, offset);

        if (import) |held| {
            const end = @min(held.end, @as(u32, @intCast(bytes.len)));

            if (lexed_closed(bytes, held.start, held.end)) {
                const statement = bytes[held.head..end];

                invoked_stepping(bytes, offset, end, reading, invocation);
                try out.push(bytes[offset..held.head]);
                try use_sorted(statement, widths, &formatter.uses, &formatter.keys, out);

                assert(end <= bytes.len);

                return end;
            }
        }

        const stop = @min(line_end(bytes, offset) + 1, @as(u32, @intCast(bytes.len)));

        try out.push(bytes[offset..stop]);
        invoked_stepping(bytes, offset, stop, reading, invocation);

        assert(stop <= bytes.len);

        return stop;
    }

    fn normalized(formatter: *Formatter) error{Overflow}![]const u8 {
        const bytes = formatter.scratch.const_slice();
        if (std.mem.findScalar(u8, bytes, '\r') == null) return bytes;

        formatter.staged.clear();

        var offset: usize = 0;

        while (offset < bytes.len) {
            const found = std.mem.findScalarPos(u8, bytes, offset, '\r') orelse break;
            const paired = found + 1 < bytes.len and bytes[found + 1] == '\n';

            try formatter.staged.push(bytes[offset..found]);

            if (!paired) try formatter.staged.push_byte('\r');

            offset = found + 1;
        }

        try formatter.staged.push(bytes[offset..]);

        assert(formatter.staged.count() <= bytes.len);

        return formatter.staged.const_slice();
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

const Aliased = struct {
    alias: ?[]const u8,
    name: []const u8,
};

const Argued = struct {
    compared: u32,
    ended: bool,
    typed: bool,

    const fresh: Argued = .{ .compared = 0, .ended = false, .typed = true };
};

const Arrow = enum {
    closed,
    found,
    pending,
};

const Arrowing = struct {
    braced: u32,
    depth: u32,
    lambda: bool,
    prior: ?u32,
};

const Element = struct {
    end: u32,
    head: u32,
    past: u32,
};

const Import = struct {
    end: u32,
    head: u32,
    start: u32,

    const empty: Import = .{ .end = 0, .head = 0, .start = 0 };
};

const Lexed = struct {
    braces: i32,
    brackets: i32,
    code_end: u32,
    invoked: bool,
    lexing: Lexing,
    parens: i32,
};

const Lexing = struct {
    comments: u32,
    hashes: u32,
    quoted: bool,
    raw: bool,

    const clean: Lexing = .{ .comments = 0, .hashes = 0, .quoted = false, .raw = false };

    fn inside(lexing: Lexing) bool {
        if (lexing.raw) assert(!lexing.quoted);
        if (!lexing.raw) assert(lexing.hashes == 0);

        if (lexing.comments > 0) {
            assert(!lexing.raw);
            assert(!lexing.quoted);
        }

        return lexing.comments > 0 or lexing.quoted or lexing.raw;
    }
};

const Parsing = union(enum) {
    abstained,
    failed,
    next: u32,
};

const Path = struct {
    from: u32,
    to: u32,
};

const Raw = struct {
    hashes: u32,
    past: u32,
};

const Reading = struct {
    depth: i32,
    lexing: Lexing,
    macros: ?i32,

    const initial: Reading = .{ .depth = 0, .lexing = .clean, .macros = null };

    fn verbatim(reading: Reading) bool {
        if (reading.macros) |macros| assert(macros < reading.depth);

        if (reading.lexing.inside()) return true;
        return reading.macros != null;
    }
};

const Segment = struct {
    end: u32,
    past: u32,
};

const UseList = struct {
    close: u32,
    depth: u32,
    open: u32,
};

const Invocation = struct {
    depth: i32,
    inside: ?i32,

    const outside: Invocation = .{ .depth = 0, .inside = null };
};

const arm_give_max: u32 = 8;
const arm_scan_max: u32 = 256;
const attribute_lines_max: u32 = 64;
const file_head_max: u32 = 4096;
const give_climb_max: u32 = 8;
const give_guard_max: u32 = 16;
const give_marks_max: u32 = 1 << 12;
const give_passes: u32 = 3;
const import_item_max: u32 = 128;
const import_run_max: u32 = 256;
const macro_rule_max: u32 = 8;
const pattern_scan_max: u32 = 512;
const rank_crate: u8 = 2;
const rank_glob: u8 = 4;
const rank_list: u8 = 5;
const rank_name: u8 = 3;
const rank_self: u8 = 0;
const rank_super: u8 = 1;
const use_bytes_max: u32 = 1 << 16;
const use_list_max: u32 = 64;

const arm_stops = [_][]const u8{
    "=>",
    "else",
    "fn",
    "if",
    "impl",
    "loop",
    "mod",
    "trait",
    "unsafe",
    "while",
};

const give_operators = [_][]const u8{
    "!=",
    "%",
    "&&",
    "*",
    "+",
    "-",
    "/",
    "<=",
    "==",
    ">=",
    "^",
    "||",
};

const item_words = [_][]const u8{
    "async",
    "const",
    "default",
    "enum",
    "extern",
    "fn",
    "impl",
    "macro_rules",
    "mod",
    "pub",
    "static",
    "struct",
    "trait",
    "type",
    "union",
    "unsafe",
    "use",
};

const literal_keywords = [_][]const u8{ "Self", "crate", "false", "self", "super", "true" };
const lone_keeps = [_][]const u8{ "!", "..", "," };
const macro_heads = [_][]const u8{ "pub", "unsafe" };
const path_words = [_][]const u8{ "$", "::", "Self", "crate", "self", "super" };

pub const policy: brace.Policy = .{
    .align_colons = false,
    .angle_calls = false,
    .angle_spreads = false,
    .angle_objects = false,
    .angle_types = true,
    .arm_bars = true,
    .arm_empties = true,
    .arm_flattens = true,
    .arm_guards = true,
    .arrow_after = &.{},
    .arrow_bodies = false,
    .arrow_commas = false,
    .arrow_parens = false,
    .asm_operands = false,
    .assign_groups = false,
    .assign_joins = true,
    .assign_lines = false,
    .assign_values = false,
    .assign_wraps = true,
    .chain_lets = true,
    .chain_simples = false,
    .chain_soles = true,
    .chain_hugs = true,
    .chain_joins = true,
    .chain_groups = false,
    .chain_width = 60,
    .call_budgets = true,
    .call_nests = true,
    .call_width = 60,
    .attribute_ends = true,
    .attribute_joins = true,
    .attribute_spans = true,
    .attribute_width = 70,
    .attribute_words = &.{"derive"},
    .bar_aligns = true,
    .bar_levels = false,
    .binary_lines = false,
    .binary_parts = false,
    .binding_bases = &.{"if"},
    .binding_codes = false,
    .binding_leads = true,
    .binder_words = &.{},
    .binding_words = &.{
        &.{ "*", "/", "%" },
        &.{ "+", "-" },
        &.{ "<<", ">>" },
        &.{"&"},
        &.{"^"},
        &.{"|"},
        &.{ "==", "!=", "<", ">", "<=", ">=" },
        &.{"&&"},
        &.{"||"},
    },
    .blank_edges = true,
    .blank_max = 1,
    .block_chains = true,
    .block_joins = true,
    .block_leads = &.{
        "->",
        "async",
        "do",
        "else",
        "enum",
        "extern",
        "fn",
        "for",
        "gen",
        "if",
        "impl",
        "loop",
        "match",
        "mod",
        "move",
        "struct",
        "trait",
        "try",
        "union",
        "unsafe",
        "while",
    },
    .block_words = &.{},
    .body_owns = false,
    .body_settles = false,
    .body_parts = false,
    .body_words = &.{},
    .brace_bodies = true,
    .brace_comments = true,
    .brace_continues = true,
    .brace_counts = false,
    .brace_dedents = true,
    .brace_hugs = false,
    .brace_leads = false,
    .brace_levels = true,
    .brace_pairs = true,
    .brace_parts = false,
    .brace_spaces = true,
    .brace_spans = false,
    .brace_words = &.{},
    .branch_joins = true,
    .branch_width = 50,
    .branch_words = &.{"if"},
    .bracket_types = false,
    .build_blocks = false,
    .carriage_breaks = true,
    .callee_marks = &.{},
    .callee_words = &.{},
    .cast_joins = true,
    .cast_words = &.{},
    .clause_bases = true,
    .clause_ends = true,
    .clause_heads = &.{},
    .clause_lines = false,
    .clause_values = &.{"type"},
    .clause_words = &.{"where"},
    .close_hugs = false,
    .colon_continues = true,
    .comma_continues = false,
    .comma_adds = false,
    .comma_drops = false,
    .comma_joins = true,
    .comma_parts = true,
    .comment_carries = false,
    .comment_dedents = true,
    .comment_gaps = false,
    .comment_leads = false,
    .comment_levels = false,
    .comment_opens = false,
    .comment_spaces = false,
    .comment_suffix = false,
    .comment_tails = true,
    .compose_parts = false,
    .construct_words = &.{},
    .continue_words = &.{
        "!=",
        "&&",
        "*",
        "+",
        "-",
        "/",
        "<",
        "<<",
        "<=",
        "==",
        ">=",
        ">>",
        "^",
        "as",
        "|",
        "||",
    },
    .convention_strings = false,
    .dangling_blanks = false,
    .define_joins = true,
    .define_widths = true,
    .define_words = &.{"fn"},
    .declare_lines = false,
    .declaration_words = &.{},
    .declare_words = &.{},
    .decorators = false,
    .dedent_words = &.{},
    .document_blocks = false,
    .edge_blanks = false,
    .else_width = 50,
    .empty_follows = &.{},
    .empty_joins = true,
    .empty_semis = false,
    .empty_words = &.{},
    .end_words = &.{},
    .field_width = 0,
    .fill_reserve = 1,
    .follow_heads = &.{"for"},
    .follow_words = &.{},
    .gap_words = &.{},
    .generic_levels = true,
    .generic_nests = true,
    .generic_parts = true,
    .group_words = &.{},
    .head_blanks = true,
    .head_blocks = true,
    .head_stops = &.{},
    .header_braces = true,
    .header_extends = true,
    .header_joins = true,
    .header_levels = false,
    .header_lines = true,
    .header_parens = false,
    .header_widths = true,
    .header_words = &.{ "for", "if", "match", "while" },
    .heritage_parts = false,
    .hole_spaces = false,
    .hug_braces = false,
    .hug_lambdas = true,
    .hug_lasts = false,
    .hug_soles = false,
    .hug_words = &.{ "!", "::", "fn" },
    .index_continues = true,
    .inline_comments = false,
    .inline_layout = false,
    .item_words = &.{"impl"},
    .key_numbers = false,
    .key_quotes = false,
    .key_words = &.{},
    .keyword_gaps = false,
    .label_lines = false,
    .label_words = &.{},
    .lambda_flattens = true,
    .lead_words = &.{"/*"},
    .level_words = &.{"else"},
    .lifetime_tight = true,
    .link_levels = true,
    .link_nests = true,
    .link_spans = true,
    .list_blanks = true,
    .list_comments = true,
    .list_fills = true,
    .list_groups = true,
    .list_hugs = true,
    .list_leads = &.{ "::", "use" },
    .list_mixes = 10,
    .list_tight = &.{ "::", "*" },
    .list_sorts = true,
    .list_spreads = false,
    .list_width = 98,
    .list_words = &.{ "pub", "use" },
    .literal_joins = true,
    .literal_width = 18,
    .macro_bodies = true,
    .macro_defines = true,
    .macro_gaps = true,
    .macro_indents = true,
    .macro_spans = true,
    .member_words = &.{},
    .nested_levels = true,
    .number_forms = false,
    .object_words = &.{},
    .operand_joins = true,
    .operand_levels = true,
    .operand_words = &.{ "Self", "await", "crate", "self", "super" },
    .operator_words = &.{},
    .order_words = &.{},
    .parameter_words = &.{},
    .pattern_frames = true,
    .pattern_words = &.{"match"},
    .postfix_words = &.{},
    .prefix_words = &.{ "$", "@", "'" },
    .printed_gaps = false,
    .raise_hugged = true,
    .regex_flags = false,
    .sentinel_colons = false,
    .sequence_lines = false,
    .sequence_stops = &.{},
    .return_parens = false,
    .rest_binds = false,
    .root_joins = true,
    .row_parts = false,
    .sibling_levels = false,
    .signature_words = &.{},
    .skip_words = &.{ "rustfmt", "::", "skip" },
    .slice_colons = true,
    .sole_hugs = false,
    .sole_joins = true,
    .source_gaps = false,
    .source_values = &.{},
    .source_words = &.{"|"},
    .spaced_words = &.{},
    .span_levels = false,
    .spread_blanks = false,
    .spread_owns = false,
    .spread_values = false,
    .tight_from_source = &.{ "!", "*", "+", ":", "<", ">", ">>", "?" },
    .spec_depths = false,
    .special_macros = &.{
        .{ .word = "assert", .leading = 1 },
        .{ .word = "assert_eq", .leading = 2 },
        .{ .word = "assert_ne", .leading = 2 },
        .{ .word = "debug", .leading = 0 },
        .{ .word = "debug_assert", .leading = 1 },
        .{ .word = "debug_assert_eq", .leading = 2 },
        .{ .word = "debug_assert_ne", .leading = 2 },
        .{ .word = "eprint", .leading = 0 },
        .{ .word = "eprintln", .leading = 0 },
        .{ .word = "error", .leading = 0 },
        .{ .word = "format", .leading = 0 },
        .{ .word = "format_args", .leading = 0 },
        .{ .word = "info", .leading = 0 },
        .{ .word = "panic", .leading = 0 },
        .{ .word = "print", .leading = 0 },
        .{ .word = "println", .leading = 0 },
        .{ .word = "trace", .leading = 0 },
        .{ .word = "unreachable", .leading = 0 },
        .{ .word = "warn", .leading = 0 },
        .{ .word = "write", .leading = 1 },
        .{ .word = "writeln", .leading = 1 },
    },
    .string_quotes = false,
    .template_spans = false,
    .template_units = false,
    .ternary_colon = false,
    .ternary_levels = false,
    .ternary_parts = false,
    .test_joins = false,
    .tight_words = &.{ "#", "::" },
    .type_leads = &.{},
    .type_words = &.{},
    .unary_tight = false,
    .unary_words = &.{ "!", "&", "*", "-", "..", "..=" },
    .union_parts = false,
    .value_cap = 0,
    .value_columns = false,
    .value_words = &.{},
    .variant_width = 35,
    .verbatim_words = &.{},
    .units = false,
    .width_lists = false,
    .wrap_words = &.{},
};

const tails: brace.TailsType(Kind) = .{
    .argued = argued,
    .arms = arms,
    .attributes = attributes,
    .bodies = bodies,
    .bounds = bounds,
    .call_width = policy.call_width,
    .chained = chained,
    .compares = compares,
    .flattens = flattens,
    .forces = forces,
    .items = items,
    .keeps = keeps,
    .lambda = lambda,
    .lasts = lasts,
    .lines = lined,
    .literal = policy.literal_width,
    .operands = operands,
    .owes = owes,
    .width = policy.else_width,
    .wraps = wraps,
};

fn worded(byte: u8) bool {
    if (byte < '0') return false;

    const result = std.ascii.isAlphanumeric(byte) or byte == '_';

    if (result) assert(byte < 0x80);
    if (std.ascii.isWhitespace(byte)) assert(!result);

    return result;
}

fn indent_of(line: []const u8) u32 {
    assert(line.len <= std.math.maxInt(u32));

    var held: u32 = 0;

    while (held < line.len) : (held += 1) {
        if (line[held] != ' ') break;
    }

    assert(held <= line.len);
    if (held < line.len) assert(line[held] != ' ');

    return held;
}

fn line_end(bytes: []const u8, offset: u32) u32 {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    var held = offset;

    while (held < bytes.len) : (held += 1) {
        if (bytes[held] == '\n') break;
    }

    assert(held >= offset);
    if (held < bytes.len) assert(bytes[held] == '\n');

    return held;
}

fn found_at(haystack: []const u8, needle: []const u8) ?u32 {
    assert(needle.len > 0);
    assert(haystack.len <= std.math.maxInt(u32));

    const found = std.mem.find(u8, haystack, needle) orelse return null;

    assert(found + needle.len <= haystack.len);

    return @intCast(found);
}

fn attributed(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const body = trim_ascii(line);

    assert(body.len <= line.len);

    if (!std.mem.startsWith(u8, body, "#[")) return false;
    return std.mem.endsWith(u8, body, "]");
}

fn skips(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    return found_at(line, "rustfmt::skip") != null;
}

fn skipped_file(source: []const u8) bool {
    assert(source.len <= std.math.maxInt(u32));

    var scan: u32 = 0;

    for (0..file_head_max) |_| {
        if (scan >= source.len) return false;

        const stop = line_end(source, scan);
        const line = trim_ascii(source[scan..@min(stop, source.len)]);

        scan = stop + 1;

        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (!std.mem.startsWith(u8, line, "#![")) return false;
        if (skips(line)) return true;
    }

    assert(scan >= file_head_max);

    return false;
}

fn use_at(line: []const u8) ?u32 {
    assert(line.len <= std.math.maxInt(u32));

    var held = indent_of(line);

    if (std.mem.startsWith(u8, line[held..], "pub")) {
        held += 3;

        if (std.mem.startsWith(u8, line[held..], "(")) {
            const close = found_at(line[held..], ")") orelse return null;

            held += close + 1;
        }

        held += indent_of(line[held..]);
    }

    if (!std.mem.startsWith(u8, line[held..], "use ")) return null;

    assert(held + 4 <= line.len);

    return held;
}

fn macroed(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const body = std.mem.trimEnd(u8, line, ascii_whitespace);

    assert(body.len <= line.len);

    if (std.mem.endsWith(u8, body, "! {")) return true;
    if (std.mem.endsWith(u8, body, "!{")) return true;
    return found_at(line, "macro_rules!") != null;
}

fn lexed(held: Lexing, line: []const u8) Lexed {
    assert(line.len < std.math.maxInt(u32));
    if (!held.raw) assert(held.hashes == 0);

    var lexing = held;
    var braces: i32 = 0;
    var brackets: i32 = 0;
    var parens: i32 = 0;
    var invoked = false;
    var index: u32 = 0;
    var code_end: u32 = 0;

    while (index < line.len) {
        const rest = line[index..];
        const commented = lexing.comments > 0;

        if (!lexing.inside()) {
            if (std.mem.startsWith(u8, rest, "//")) break;

            switch (rest[0]) {
                '{' => braces += 1,
                '}' => braces -= 1,
                '[' => brackets += 1,
                ']' => brackets -= 1,
                '(' => parens += 1,
                ')' => parens -= 1,
                '!' => invoked = invoked or bang_invoked(line, index),
                else => {},
            }
        }

        const past = index + if (lexing.inside())
            lexed_inside(&lexing, rest)
        else
            lexed_code(&lexing, line, index);

        assert(past > index);
        assert(past <= line.len);

        const outside = !commented and lexing.comments == 0;

        if (outside) {
            if (!is_ascii_whitespace(rest[0])) code_end = past;
        }

        index = past;
    }

    assert(@abs(braces) <= line.len);
    assert(@abs(brackets) <= line.len);
    assert(@abs(parens) <= line.len);
    assert(code_end <= line.len);

    return .{
        .braces = braces,
        .brackets = brackets,
        .code_end = code_end,
        .invoked = invoked,
        .lexing = lexing,
        .parens = parens,
    };
}

fn bang_invoked(line: []const u8, index: u32) bool {
    assert(index < line.len);
    assert(line[index] == '!');

    if (index == 0) return false;
    if (!is_identifier_part(line[index - 1])) return false;

    const after = std.mem.findNonePos(u8, line, index + 1, " \t") orelse return false;

    return switch (line[after]) {
        '(', '[', '{' => true,
        else => false,
    };
}

fn lexed_inside(lexing: *Lexing, rest: []const u8) u32 {
    assert(lexing.inside());
    assert(rest.len > 0);

    if (lexing.comments > 0) {
        if (std.mem.startsWith(u8, rest, "*/")) {
            lexing.comments -= 1;

            return 2;
        }

        if (std.mem.startsWith(u8, rest, "/*")) {
            lexing.comments += 1;

            return 2;
        }

        return 1;
    }

    if (lexing.raw) {
        if (rest[0] != '"') return 1;
        if (!hashed(rest[1..], lexing.hashes)) return 1;

        const past = 1 + lexing.hashes;

        lexing.raw = false;
        lexing.hashes = 0;

        assert(past < std.math.maxInt(u32));

        return past;
    }

    assert(lexing.quoted);

    if (rest[0] == '\\') {
        assert(@min(rest.len, 2) < std.math.maxInt(u32));

        return @intCast(@min(rest.len, 2));
    }

    if (rest[0] == '"') lexing.quoted = false;

    return 1;
}

fn lexed_code(lexing: *Lexing, line: []const u8, index: u32) u32 {
    assert(!lexing.inside());
    assert(index < line.len);

    const rest = line[index..];

    if (std.mem.startsWith(u8, rest, "/*")) {
        lexing.comments = 1;

        return 2;
    }

    if (raw_opened(line, index)) |raw| {
        assert(raw.past > index);

        lexing.raw = true;
        lexing.hashes = raw.hashes;

        assert(raw.past - index <= line.len);

        return raw.past - index;
    }

    if (rest[0] == '"') {
        lexing.quoted = true;

        return 1;
    }

    if (rest[0] == '\'') return charactered(rest);
    return 1;
}

fn hashed(rest: []const u8, hashes: u32) bool {
    if (rest.len < hashes) return false;

    for (rest[0..hashes]) |byte| {
        if (byte != '#') return false;
    }

    return true;
}

fn raw_opened(line: []const u8, index: u32) ?Raw {
    assert(index < line.len);

    if (index > 0) {
        if (worded(line[index - 1])) return null;
    }

    var at = index;
    const prefixed = line[at] == 'b' or line[at] == 'c';

    if (prefixed) at += 1;
    if (at >= line.len) return null;
    if (line[at] != 'r') return null;

    var scan = at + 1;

    while (scan < line.len) : (scan += 1) {
        if (line[scan] != '#') break;
    }

    if (scan >= line.len) return null;
    if (line[scan] != '"') return null;

    assert(scan > at);

    return .{ .hashes = scan - at - 1, .past = scan + 1 };
}

fn charactered(rest: []const u8) u32 {
    assert(rest.len > 0);
    assert(rest[0] == '\'');

    if (rest.len < 3) return 1;

    if (rest[1] == '\\') {
        var scan: u32 = 3;

        while (scan < rest.len) : (scan += 1) {
            if (rest[scan] == '\'') {
                assert(scan + 1 < std.math.maxInt(u32));

                return scan + 1;
            }
        }

        return 1;
    }

    const width: u32 = std.unicode.utf8ByteSequenceLength(rest[1]) catch 1;
    if (1 + width >= rest.len) return 1;
    if (rest[1 + width] != '\'') return 1;
    assert(2 + width < std.math.maxInt(u32));

    return 2 + width;
}

fn stepped(held: Reading, line: []const u8) Reading {
    if (held.macros) |macros| assert(macros < held.depth);
    assert(line.len <= std.math.maxInt(u32));

    var reading = held;
    const line_lexed = lexed(held.lexing, line);
    const opens = line_lexed.braces;
    const opened = reading.macros == null and opens > 0 and macroed(line);

    reading.lexing = line_lexed.lexing;

    if (opened) reading.macros = reading.depth;

    reading.depth += opens;

    if (reading.macros) |macros| {
        if (reading.depth <= macros) reading.macros = null;
    }

    if (reading.macros) |macros| assert(macros < reading.depth);

    return reading;
}

fn skipping(bytes: []const u8, offset: u32) ?u32 {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    var held = false;
    var scan = offset;

    while (scan < bytes.len) {
        const stop = line_end(bytes, scan);
        const line = bytes[scan..stop];
        if (!attributed(line)) break;

        if (!held) held = skips(line);

        scan = stop + 1;
    }

    if (!held) return null;

    var depth: i32 = 0;
    var lexing: Lexing = .clean;

    while (scan < bytes.len) {
        const stop = line_end(bytes, scan);
        const line = bytes[scan..stop];
        const line_lexed = lexed(lexing, line);
        const body = line[0..line_lexed.code_end];

        lexing = line_lexed.lexing;
        depth += line_lexed.braces;
        scan = stop + 1;

        if (depth > 0) continue;
        if (lexing.inside()) continue;
        if (std.mem.endsWith(u8, body, ";")) break;
        if (std.mem.endsWith(u8, body, "}")) break;
    }

    assert(scan > offset);

    return scan;
}

fn lexed_closed(bytes: []const u8, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to <= bytes.len + 1);

    var lexing: Lexing = .clean;
    var scan = from;

    while (scan < to) {
        const stop = line_end(bytes, scan);

        lexing = lexed(lexing, bytes[scan..stop]).lexing;
        scan = stop + 1;
    }

    return !lexing.inside();
}

fn imported(bytes: []const u8, offset: u32) ?Import {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    var scan = offset;

    while (scan < bytes.len) {
        scan = attribute_end(bytes, scan) orelse break;
    }

    const opened = line_end(bytes, scan);

    _ = use_at(bytes[scan..opened]) orelse return null;

    const head = scan;
    var end = scan;
    var lexing: Lexing = .clean;

    while (end < bytes.len) {
        const stop = line_end(bytes, end);
        const line = bytes[end..stop];
        const line_lexed = lexed(lexing, line);
        const body = line[0..line_lexed.code_end];

        lexing = line_lexed.lexing;
        end = stop + 1;

        if (std.mem.endsWith(u8, body, ";")) {
            assert(end > head);
            assert(head >= offset);

            return .{ .end = end, .head = head, .start = offset };
        }
    }

    return null;
}

fn attribute_end(bytes: []const u8, offset: u32) ?u32 {
    assert(offset < bytes.len);

    const first = line_end(bytes, offset);

    if (attributed(bytes[offset..first])) {
        assert(first + 1 > offset);

        return first + 1;
    }

    if (!std.mem.startsWith(u8, trim_ascii(bytes[offset..first]), "#[")) return null;

    var depth: i32 = 0;
    var lexing: Lexing = .clean;
    var scan = offset;

    for (0..attribute_lines_max) |_| {
        if (scan >= bytes.len) return null;

        const stop = line_end(bytes, scan);
        const line_lexed = lexed(lexing, bytes[scan..stop]);
        const body = bytes[scan..][0..line_lexed.code_end];

        lexing = line_lexed.lexing;
        depth += line_lexed.brackets;

        assert(stop >= scan);

        if (depth <= 0) {
            if (lexing.inside()) return null;
            if (!std.mem.endsWith(u8, body, "]")) return null;
            assert(stop + 1 > scan);

            return stop + 1;
        }

        scan = stop + 1;
    }

    return null;
}

fn collected(bytes: []const u8, offset: u32, held: []Import) u32 {
    assert(held.len == import_run_max);
    assert(offset < bytes.len);

    var import_count: u32 = 0;
    var indent: ?u32 = null;
    var scan = offset;

    while (import_count < held.len) {
        if (skipping(bytes, scan) != null) break;

        const import = imported(bytes, scan) orelse break;
        const stop = line_end(bytes, import.head);
        const level = indent_of(bytes[import.head..stop]);
        const indent_held = indent orelse level;

        indent = indent_held;

        if (level != indent_held) break;
        if (!lexed_closed(bytes, import.start, import.end)) break;

        held[import_count] = import;
        import_count += 1;
        scan = import.end;
    }

    assert(import_count <= held.len);
    if (import_count > 0) assert(held[0].start == offset);

    return import_count;
}

fn aliased(text: []const u8) Aliased {
    assert(text.len <= std.math.maxInt(u32));

    const held = trim_ascii(text);

    assert(held.len <= text.len);

    const at = found_at(held, " as ") orelse return .{ .alias = null, .name = unraw(held) };
    const name = std.mem.trimEnd(u8, held[0..at], ascii_whitespace);
    const alias = trim_ascii(held[at + 4 ..]);

    assert(name.len <= at);

    return .{ .alias = unraw(alias), .name = unraw(name) };
}

fn unraw(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    if (!std.mem.startsWith(u8, text, "r#")) return text;

    assert(text.len >= 2);

    return text[2..];
}

fn ranked_segment(text: []const u8) u8 {
    assert(text.len <= std.math.maxInt(u32));

    if (walk.text_is(text, "self")) return rank_self;
    if (walk.text_is(text, "super")) return rank_super;
    if (walk.text_is(text, "crate")) return rank_crate;
    if (walk.text_is(text, "*")) return rank_glob;
    if (std.mem.startsWith(u8, text, "{")) return rank_list;

    if (text.len > 0) assert(text[0] != '{');

    return rank_name;
}

fn compared(left: []const u8, right: []const u8) std.math.Order {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    return ranked_pair(left, right) orelse listed_before(left, right);
}

fn ranked_pair(left: []const u8, right: []const u8) ?std.math.Order {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    const one = aliased(left).name;
    const two = aliased(right).name;
    const held = ranked_segment(one);
    const other = ranked_segment(two);

    assert(held <= rank_list);
    assert(other <= rank_list);

    if (held != other) return std.math.order(held, other);
    if (held == rank_list) return null;
    if (!std.mem.eql(u8, one, two)) return ordering(brace.versioned(one, two));
    return .eq;
}

fn listed_before(left: []const u8, right: []const u8) std.math.Order {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    var held = element_at(left, 1);
    var other = element_at(right, 1);

    for (0..import_item_max) |_| {
        const one = held orelse return presence_order(false, other != null);
        const two = other orelse return presence_order(true, false);
        const found = treed_before(left[one.head..one.end], right[two.head..two.end]);
        if (found != .eq) return found;

        held = element_at(left, one.past);
        other = element_at(right, two.past);
    }

    return .eq;
}

fn treed_before(left: []const u8, right: []const u8) std.math.Order {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    var held: u32 = 0;
    var other: u32 = 0;

    for (0..import_item_max) |_| {
        if (held >= left.len) break;
        if (other >= right.len) break;

        const one = segment(left, held, @intCast(left.len));
        const two = segment(right, other, @intCast(right.len));

        const found = ranked_pair(left[held..one.end], right[other..two.end]) orelse
            listed_bytes(left[held..one.end], right[other..two.end]);

        if (found != .eq) return found;

        held = one.past;
        other = two.past;
    }

    return presence_order(held < left.len, other < right.len);
}

fn presence_order(left: bool, right: bool) std.math.Order {
    const result = std.math.order(@intFromBool(left), @intFromBool(right));

    if (left == right) assert(result == .eq);
    if (result == .lt) assert(right);

    return result;
}

fn element_at(text: []const u8, from: u32) ?Element {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const stop: u32 = @intCast(text.len -| 1);
    const head = skipped(text, from);
    if (head >= stop) return null;

    var depth: i32 = 0;
    var scan = head;

    while (scan < stop) : (scan += 1) {
        const byte = text[scan];
        const separates = byte == ',' and depth == 0;
        if (separates) break;

        if (byte == '{') depth += 1;
        if (byte == '}') depth -= 1;
    }

    var end = scan;

    while (end > head) : (end -= 1) {
        if (!is_ascii_whitespace(text[end - 1])) break;
    }

    assert(head <= end);
    assert(end <= scan);

    return .{ .end = end, .head = head, .past = scan + 1 };
}

fn skipped(text: []const u8, from: u32) u32 {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    var held = from;

    while (held < text.len) : (held += 1) {
        if (!is_ascii_whitespace(text[held])) break;
    }

    if (held < text.len) assert(!is_ascii_whitespace(text[held]));

    return held;
}

fn digits_at(text: []const u8, from: u32) u32 {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    var held = from;

    while (held < text.len) : (held += 1) {
        if (!std.ascii.isDigit(text[held])) break;
    }

    if (held < text.len) assert(!std.ascii.isDigit(text[held]));

    return held;
}

fn listed_bytes(left: []const u8, right: []const u8) std.math.Order {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    var held = skipped(left, 0);
    var other = skipped(right, 0);

    while (held < left.len) {
        if (other >= right.len) break;

        const digits = std.ascii.isDigit(left[held]) and std.ascii.isDigit(right[other]);

        if (digits) {
            const held_end = digits_at(left, held);
            const other_end = digits_at(right, other);
            const counted = std.math.order(held_end - held, other_end - other);

            const found = if (counted != .eq)
                counted
            else
                std.mem.order(u8, left[held..held_end], right[other..other_end]);

            if (found != .eq) return found;

            held = skipped(left, held_end);
            other = skipped(right, other_end);

            continue;
        }

        const one = brace.ranked(left[held]);
        const two = brace.ranked(right[other]);
        if (one != two) return std.math.order(one, two);

        held = skipped(left, held + 1);
        other = skipped(right, other + 1);
    }

    return std.math.order(left.len - held, right.len - other);
}

fn ordering(held: bool) std.math.Order {
    const result: std.math.Order = if (held) .lt else .gt;

    assert(result != .eq);

    return result;
}

fn segment(bytes: []const u8, from: u32, to: u32) Segment {
    assert(from <= to);
    assert(to <= bytes.len);

    var depth: i32 = 0;
    var held = from;

    while (held < to) : (held += 1) {
        const separated = depth == 0 and std.mem.startsWith(u8, bytes[held..to], "::");
        if (separated) return .{ .end = held, .past = held + 2 };

        if (bytes[held] == '{') depth += 1;
        if (bytes[held] == '}') depth -= 1;
    }

    return .{ .end = to, .past = to };
}

fn pathed(bytes: []const u8, held: Import) Path {
    assert(held.head < held.end);
    assert(held.head <= bytes.len);

    const stop = line_end(bytes, held.head);
    const used = use_at(bytes[held.head..stop]) orelse 0;
    const from = held.head + used + @as(u32, "use ".len);
    var to = @min(held.end, @as(u32, @intCast(bytes.len)));

    while (to > from) : (to -= 1) {
        if (bytes[to - 1] == ';') break;
    }

    const result: Path = .{ .from = from, .to = @max(to -| 1, from) };

    assert(result.from <= result.to);

    return result;
}

fn precedes_import(bytes: []const u8, left: Import, right: Import) bool {
    assert(left.head < left.end);
    assert(right.head < right.end);
    assert(bytes.len <= std.math.maxInt(u32));

    const left_path = pathed(bytes, left);
    const right_path = pathed(bytes, right);
    var held = left_path.from;
    var other = right_path.from;

    while (held < left_path.to) {
        if (other >= right_path.to) break;

        const one = segment(bytes, held, left_path.to);
        const two = segment(bytes, other, right_path.to);
        const found = compared(bytes[held..one.end], bytes[other..two.end]);
        if (found != .eq) return found == .lt;

        held = one.past;
        other = two.past;
    }

    if (held < left_path.to) return false;
    return other < right_path.to;
}

fn ordered_imports(bytes: []const u8, held: []Import) void {
    assert(held.len >= 2);
    assert(held.len <= import_run_max);
    assert(bytes.len <= std.math.maxInt(u32));

    for (1..held.len) |index| {
        var scan = index;

        while (scan > 0) : (scan -= 1) {
            if (!precedes_import(bytes, held[scan], held[scan - 1])) break;

            std.mem.swap(Import, &held[scan], &held[scan - 1]);
        }
    }
}

fn stepping(bytes: []const u8, from: u32, to: u32, reading: *Reading) void {
    assert(from <= to);
    assert(bytes.len <= std.math.maxInt(u32));

    var scan = from;

    while (scan < to) {
        const stop = line_end(bytes, scan);

        reading.* = stepped(reading.*, bytes[scan..stop]);
        scan = stop + 1;
    }
}

fn written(
    bytes: []const u8,
    from: u32,
    to: u32,
    reading: *Reading,
    out: *Buffer,
) error{Overflow}!void {
    assert(from < to);
    assert(from < bytes.len);

    stepping(bytes, from, to, reading);

    try out.push(bytes[from..@min(to, bytes.len)]);
}

fn invoked_stepping(
    bytes: []const u8,
    from: u32,
    to: u32,
    reading: *Reading,
    invocation: *Invocation,
) void {
    assert(from <= to);
    assert(to <= bytes.len);

    var scan = from;

    while (scan < to) {
        const stop = line_end(bytes, scan);
        const line = bytes[scan..stop];
        const line_lexed = lexed(reading.lexing, line);
        const delta = line_lexed.braces + line_lexed.brackets + line_lexed.parens;
        const invocation_opens = invocation.inside == null and line_lexed.invoked and delta > 0;

        if (invocation_opens) invocation.inside = invocation.depth;

        invocation.depth += delta;

        if (invocation.inside) |held| {
            if (invocation.depth <= held) invocation.inside = null;
        }

        reading.* = stepped(reading.*, line);
        scan = stop + 1;
    }
}

fn use_sorted(
    statement: []const u8,
    widths: brace.Widths,
    uses: *Buffer,
    keys: *Buffer,
    out: *Buffer,
) error{Overflow}!void {
    assert(statement.len > 0);
    assert(widths.line > 0);

    const commented = std.mem.find(u8, statement, "//") != null or
        std.mem.find(u8, statement, "/*") != null;

    if (commented) return out.push(statement);
    if (statement.len > uses.capacity()) return out.push(statement);

    uses.clear();
    try uses.push(statement);

    for (0..use_list_max) |_| {
        const changed = use_pass(uses, widths, keys) catch return out.push(statement);
        if (!changed) break;
    }

    try out.push(uses.const_slice());
}

fn use_pass(uses: *Buffer, widths: brace.Widths, keys: *Buffer) error{Overflow}!bool {
    assert(widths.line > 0);
    assert(uses.count() > 0);

    var lists: [use_list_max]UseList = undefined;
    const count = use_lists(uses.const_slice(), &lists) orelse return false;
    var deepest: u32 = 0;

    for (lists[0..count]) |list| deepest = @max(deepest, list.depth);

    var depth = deepest + 1;

    while (depth > 0) {
        depth -= 1;

        for (lists[0..count]) |list| {
            if (list.depth != depth) continue;
            if (try use_list_sorted(uses, list, widths, keys)) return true;
        }
    }

    return false;
}

fn use_lists(statement: []const u8, lists: *[use_list_max]UseList) ?u32 {
    assert(statement.len <= use_bytes_max);

    var opens: [use_list_max]u32 = undefined;
    var height: u32 = 0;
    var count: u32 = 0;

    for (statement, 0..) |byte, index| {
        if (byte == '{') {
            if (height == use_list_max) return null;

            opens[height] = @intCast(index);
            height += 1;
        } else if (byte == '}') {
            if (height == 0) return null;
            if (count == use_list_max) return null;

            height -= 1;
            lists[count] = .{ .close = @intCast(index), .depth = height, .open = opens[height] };
            count += 1;
        } else {}
    }

    if (height != 0) return null;

    assert(count <= use_list_max);

    return count;
}

fn use_items(statement: []const u8, list: UseList, members: *[import_item_max]Span) ?u32 {
    assert(list.open < list.close);
    assert(list.close < statement.len);

    var count: u32 = 0;
    var depth: u32 = 0;
    var start = list.open + 1;

    for (list.open + 1..list.close + 1) |index| {
        const byte = statement[index];
        const ends = index == list.close or (byte == ',' and depth == 0);

        if (byte == '{') depth += 1;

        if (byte == '}') {
            if (index != list.close) depth -|= 1;
        }

        if (!ends) continue;

        const item = trim_ascii(statement[start..index]);

        if (item.len > 0) {
            if (count == import_item_max) return null;

            const offset: u32 = @intCast(@intFromPtr(item.ptr) - @intFromPtr(statement.ptr));

            members[count] = .{ .offset = offset, .length = @intCast(item.len) };
            count += 1;
        }

        start = @intCast(index + 1);
    }

    return count;
}

fn use_keyed(statement: []const u8, item: Span, keys: *Buffer) error{Overflow}!Span {
    assert(item.end() <= statement.len);
    assert(item.length > 0);

    const offset = keys.count();
    const bytes = item.text(statement);
    var index: u32 = 0;

    while (index < bytes.len) {
        const byte = bytes[index];

        if (!is_ascii_whitespace(byte)) {
            const closing = byte == ',' and use_closed_after(bytes, index + 1);

            if (!closing) try keys.push_byte(byte);

            index += 1;

            continue;
        }

        const run_end = std.mem.findNonePos(u8, bytes, index, ascii_whitespace) orelse bytes.len;
        const prior = keys.count() > offset and keys.const_slice()[keys.count() - 1] == '{';
        const closer = run_end < bytes.len and bytes[run_end] == '}';

        if (!prior) {
            if (!closer) try keys.push_byte(' ');
        }

        index = @intCast(run_end);
    }

    return .{ .offset = offset, .length = keys.count() - offset };
}

fn use_closed_after(bytes: []const u8, from: u32) bool {
    assert(from <= bytes.len);

    const found = std.mem.findNonePos(u8, bytes, from, ascii_whitespace) orelse return false;
    return bytes[found] == '}';
}

fn use_list_sorted(
    uses: *Buffer,
    list: UseList,
    widths: brace.Widths,
    keys: *Buffer,
) error{Overflow}!bool {
    assert(list.open < list.close);
    assert(widths.line > 0);

    const statement = uses.const_slice();
    var members: [import_item_max]Span = undefined;
    var keyed: [import_item_max]Span = undefined;
    var order: [import_item_max]u32 = undefined;
    const count = use_items(statement, list, &members) orelse return false;
    if (count < 2) return false;

    keys.clear();

    for (members[0..count], 0..) |item, index| {
        keyed[index] = try use_keyed(statement, item, keys);
        order[index] = @intCast(index);
    }

    use_ordered(keys.const_slice(), keyed[0..count], order[0..count]);

    var moved = false;

    for (order[0..count], 0..) |held, index| {
        if (held != index) moved = true;
    }

    if (!moved) return false;

    var permuted: [import_item_max]Span = undefined;

    for (order[0..count], 0..) |held, index| {
        permuted[index] = members[held];
    }

    const rendered = keys.count();
    const written_list = try use_list_written(statement, list, permuted[0..count], widths, keys);
    if (!written_list) return false;

    try uses.splice(.between(list.open, list.close + 1), keys.const_slice()[rendered..]);

    return true;
}

fn use_ordered(arena: []const u8, keyed: []const Span, order: []u32) void {
    assert(keyed.len == order.len);
    assert(order.len <= import_item_max);
    assert(arena.len <= std.math.maxInt(u32));

    for (1..order.len) |index| {
        var scan = index;

        while (scan > 0) : (scan -= 1) {
            const later = keyed[order[scan]].text(arena);
            const earlier = keyed[order[scan - 1]].text(arena);
            if (treed_before(later, earlier) != .lt) break;

            std.mem.swap(u32, &order[scan], &order[scan - 1]);
        }
    }
}

fn use_list_written(
    statement: []const u8,
    list: UseList,
    members: []const Span,
    widths: brace.Widths,
    out: *Buffer,
) error{Overflow}!bool {
    assert(members.len >= 2);
    assert(list.close < statement.len);
    assert(widths.line > 0);

    const after_open = std.mem.findNonePos(u8, statement, list.open + 1, " \t") orelse return false;
    const vertical = statement[after_open] == '\n';

    if (!vertical) {
        try out.push_byte('{');

        for (members, 0..) |item, index| {
            if (index > 0) try out.push(", ");

            try out.push(item.text(statement));
        }

        try out.push_byte('}');

        return true;
    }

    const head = if (std.mem.findScalarLast(u8, statement[0..list.open], '\n')) |found|
        found + 1
    else
        0;

    const indent = indent_of(statement[head..list.open]);
    const before_close = statement[0..list.close];
    const close_head = (std.mem.findScalarLast(u8, before_close, '\n') orelse return false) + 1;
    if (trim_ascii(statement[close_head..list.close]).len > 0) return false;

    try use_list_lines(statement, members, indent, widths, out);

    return true;
}

fn use_list_lines(
    statement: []const u8,
    members: []const Span,
    indent: u32,
    widths: brace.Widths,
    out: *Buffer,
) error{Overflow}!void {
    assert(members.len >= 2);
    assert(widths.line > 0);
    assert(statement.len <= std.math.maxInt(u32));
    assert(indent < std.math.maxInt(u32));

    const item_indent = indent + widths.indent;
    const room = widths.line -| (item_indent + 1);
    var nested = false;

    for (members) |item| {
        if (std.mem.findScalar(u8, item.text(statement), '{') != null) nested = true;
    }

    var line_len: u32 = 0;
    var prior_routed = false;
    var prior_spread = false;

    try out.push_byte('{');

    for (members, 0..) |item, index| {
        const bytes = item.text(statement);
        const routed = std.mem.find(u8, bytes, "::") != null;
        const spread = std.mem.findScalar(u8, bytes, '\n') != null;
        const width = walk.columns(bytes, 0, @intCast(bytes.len));
        const forced = nested and (prior_routed or routed);
        const over = line_len + 1 + width + 1 > room;
        const fresh = index == 0 or forced or spread or prior_spread or over;

        if (index > 0) try out.push_byte(',');

        if (fresh) {
            try out.push_byte('\n');

            for (0..item_indent) |_| try out.push_byte(' ');

            line_len = width + 1;
        } else {
            try out.push_byte(' ');

            line_len += 1 + width + 1;
        }

        try out.push(bytes);

        prior_routed = routed;
        prior_spread = spread;
    }

    try out.push(",\n");

    for (0..indent) |_| try out.push_byte(' ');

    try out.push_byte('}');
}

fn reordered(bytes: []const u8, out: *Buffer) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(out.empty());

    const front = front_skip(bytes);
    var held: [import_run_max]Import = @splat(.empty);
    var reading: Reading = .initial;
    var offset: u32 = front;

    try out.push(bytes[0..front]);

    while (offset < bytes.len) {
        const stop = try reordered_step(bytes, offset, &held, &reading, out);

        assert(stop > offset);

        offset = stop;
    }

    assert(out.count() == bytes.len);
}

fn reordered_step(
    bytes: []const u8,
    offset: u32,
    held: []Import,
    reading: *Reading,
    out: *Buffer,
) error{Overflow}!u32 {
    assert(offset < bytes.len);
    assert(held.len == import_run_max);

    const inside = reading.verbatim();
    const past = if (inside) null else skipping(bytes, offset);

    if (past) |stop| {
        try written(bytes, offset, stop, reading, out);

        return stop;
    }

    const import_count = if (inside) 0 else collected(bytes, offset, held);

    if (import_count < 2) {
        const stop = @min(line_end(bytes, offset) + 1, @as(u32, @intCast(bytes.len)));

        try written(bytes, offset, stop, reading, out);

        assert(stop <= bytes.len);

        return stop;
    }

    const end = held[import_count - 1].end;

    stepping(bytes, offset, end, reading);
    ordered_imports(bytes, held[0..import_count]);

    for (held[0..import_count]) |import| {
        try out.push(bytes[import.start..@min(import.end, bytes.len)]);
    }

    assert(end > offset);

    return end;
}

fn commented_line(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const text = std.mem.trimStart(u8, line, " \t");

    assert(text.len <= line.len);

    if (std.mem.startsWith(u8, text, "//")) return true;
    if (std.mem.startsWith(u8, text, "/*")) return true;
    return std.mem.startsWith(u8, text, "*");
}

fn token_at(tokens: []const Token, offset: u32) ?u32 {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    var low: u32 = 0;
    var high: u32 = @intCast(tokens.len);

    while (low < high) {
        const middle = low + @divFloor(high - low, 2);

        if (tokens[middle].offset <= offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    if (low < tokens.len) assert(tokens[low].offset > offset);
    if (low == 0) return null;

    assert(tokens[low - 1].offset <= offset);

    return low - 1;
}

fn carried_end(source: []const u8, tokens: []const Token, position: u32) bool {
    assert(position < tokens.len);
    assert(tokens[position].kind == .block_end);
    assert(source.len <= std.math.maxInt(u32));

    for (tokens[position + 1 ..]) |token| {
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;
        return word_in(&.{ "else", ".", "?" }, token.text(source));
    }

    return false;
}

fn settled(tokens: []const Token, position: u32) u32 {
    assert(position <= tokens.len);

    var scan = position;

    while (scan < tokens.len) : (scan += 1) {
        if (significant(tokens[scan])) return scan;
    }

    if (position < tokens.len) assert(!significant(tokens[position]));

    return position;
}

fn significant(token: Token) bool {
    if (token.length == 0) return false;
    if (token.kind == .comment) return false;
    return token.kind != .newline;
}

fn statement_head(source: []const u8, tokens: []const Token, position: u32) u32 {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var scan = position;

    while (scan > 0) {
        const held = scan - 1;

        switch (tokens[held].kind) {
            .block_end => {
                if (depth == 0) {
                    if (!carried_end(source, tokens, held)) return settled(tokens, scan);
                }

                depth += 1;
            },
            .block_start => {
                if (depth == 0) return settled(tokens, scan);

                depth -= 1;
            },
            .punctuation => |punctuation| switch (punctuation) {
                .bracket_close, .paren_close => depth += 1,
                .bracket_open, .paren_open => depth -|= 1,
                .semicolon => if (depth == 0) return settled(tokens, scan),
                else => {},
            },
            .comment, .identifier, .keyword, .newline, .number, .string => {},
        }

        scan = held;
    }

    const result = settled(tokens, 0);

    assert(result < tokens.len);

    return result;
}

fn block_open(tokens: []const Token, position: u32) ?u32 {
    assert(position <= tokens.len);

    var depth: u32 = 0;
    var scan = position;

    while (scan > 0) {
        const held = scan - 1;
        const kind = tokens[held].kind;

        switch (kind) {
            .block_end => depth += 1,
            .block_start => {
                if (depth == 0) {
                    assert(held <= tokens.len);

                    return held;
                }

                depth -= 1;
            },
            else => {},
        }

        scan = held;
    }

    return null;
}

fn item_headed(source: []const u8, tokens: []const Token, head: u32) bool {
    assert(head < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    const text = tokens[head].text(source);
    if (walk.text_is(text, "#")) return true;
    return word_in(&item_words, text);
}

fn behind(tokens: []const Token, position: u32) ?u32 {
    assert(position <= tokens.len);

    var scan = position;

    while (scan > 0) {
        const held = scan - 1;

        if (significant(tokens[held])) {
            assert(held <= tokens.len);

            return held;
        }

        scan = held;
    }

    return null;
}

fn chain_ended(source: []const u8, tokens: []const Token, position: u32) bool {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var end = position;

    for (0..give_guard_max) |_| {
        if (!word_in(&.{ ",", ";", "?" }, tokens[end].text(source))) break;

        end = behind(tokens, end) orelse return false;
    }

    assert(end <= position);

    if (!tokens[end].is_punctuation(.paren_close)) return false;

    const open = group_open(tokens, end) orelse return false;
    if (!tokens[open].is_punctuation(.paren_open)) return false;
    return dotted_callee(source, tokens, open);
}

fn group_open(tokens: []const Token, position: u32) ?u32 {
    assert(position <= tokens.len);

    var depth: u32 = 0;
    var scan = position;

    while (scan > 0) {
        const held = scan - 1;
        const kind = tokens[held].kind;

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) {
                assert(held <= tokens.len);

                return held;
            }

            depth -= 1;
        } else {}

        scan = held;
    }

    return null;
}

fn dotted_callee(source: []const u8, tokens: []const Token, open: u32) bool {
    assert(open < tokens.len);

    if (!tokens[open].opens_a_group()) return false;
    assert(source.len <= std.math.maxInt(u32));

    const name = behind(tokens, open) orelse return false;
    if (tokens[name].kind != .identifier) return false;

    const dot = behind(tokens, name) orelse return false;

    assert(dot < name);

    if (!tokens[dot].is_punctuation(.dot)) return false;
    return !std.mem.startsWith(u8, tokens[dot].text(source), "..");
}

fn guarded(source: []const u8, tokens: []const Token, position: u32, head: u32) bool {
    assert(position < tokens.len);
    assert(head < tokens.len);

    if (chain_ended(source, tokens, position)) return true;

    var scan = position;

    for (0..give_guard_max) |_| {
        const open = group_open(tokens, scan) orelse return false;
        if (open < head) return false;
        if (dotted_callee(source, tokens, open)) return true;

        scan = open;
    }

    return false;
}

fn stated_head(source: []const u8, tokens: []const Token, position: u32) u32 {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var head = statement_head(source, tokens, position);

    for (0..arm_give_max) |_| {
        const open = block_open(tokens, head) orelse return head;
        const matched = matching(source, tokens, open) orelse return head;

        assert(matched < open);

        head = statement_head(source, tokens, matched);
    }

    return head;
}

fn matching(source: []const u8, tokens: []const Token, open: u32) ?u32 {
    assert(open < tokens.len);
    assert(tokens[open].kind == .block_start);
    assert(source.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var scan = open;

    for (0..arm_scan_max) |_| {
        if (scan == 0) return null;

        scan -= 1;

        const token = tokens[scan];

        if (walk.is_close(token.kind)) {
            depth += 1;

            continue;
        }

        if (walk.is_open(token.kind)) {
            if (depth == 0) return null;

            depth -= 1;

            continue;
        }

        if (depth > 0) continue;
        if (token.length == 0) continue;

        const text = token.text(source);
        if (walk.text_is(text, "match")) return scan;
        if (token.is_punctuation(.semicolon)) return null;
        if (word_in(&arm_stops, text)) return null;
    }

    return null;
}

fn assigned(tokens: []const Token, position: u32) bool {
    assert(position < tokens.len);

    const held = behind(tokens, position) orelse return false;

    assert(held < position);

    return tokens[held].is_punctuation(.assign);
}

fn operated(source: []const u8, tokens: []const Token, position: u32) bool {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    const token = tokens[position];
    const text = token.text(source);
    if (word_in(&give_operators, text)) return true;

    const doubled = walk.text_is(text, "&") or walk.text_is(text, "|");
    if (!doubled) return false;
    if (position + 1 >= tokens.len) return false;

    const ahead = tokens[position + 1];
    if (!std.mem.eql(u8, ahead.text(source), text)) return false;
    return ahead.offset == token.end();
}

fn comments(source: []const u8, tokens: []const Token, gives: *ArrayType(u32)) bool {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(gives.empty());
    assert(source.len <= std.math.maxInt(u32));

    var found = false;

    for (tokens, 0..) |token, index| {
        if (token.kind != .comment) continue;

        const position: u32 = @intCast(index);
        const scan = comments_after(tokens, position);
        const valued = assigned(tokens, position);

        if (!valued) {
            if (scan >= tokens.len) continue;
            if (!operated(source, tokens, scan)) continue;
        }

        if (given(gives, statement_head(source, tokens, position))) found = true;
    }

    if (found) assert(!gives.empty());

    return found;
}

fn spilled(source: []const u8, tokens: []const Token, width: u32, gives: *ArrayType(u32)) bool {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(width > 0);
    assert(source.len <= std.math.maxInt(u32));

    var found = false;

    for (tokens, 0..) |token, index| {
        if (token.kind != .string) continue;
        if (!string_spilled(token.text(source), width)) continue;

        if (given(gives, stated_head(source, tokens, @intCast(index)))) found = true;
    }

    if (found) assert(!gives.empty());

    return found;
}

fn string_spilled(text: []const u8, width: u32) bool {
    assert(width > 0);

    if (!std.mem.startsWith(u8, text, "\"")) return false;

    const first = std.mem.findScalar(u8, text, '\n') orelse return false;
    var continued = std.mem.endsWith(u8, std.mem.trimEnd(u8, text[0..first], "\r"), "\\");
    var wide = false;
    var start = first + 1;

    while (start <= text.len) {
        const stop = std.mem.findScalarPos(u8, text, start, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[start..stop], "\r");

        wide = wide or walk.columns(line, 0, @intCast(line.len)) > width;

        if (stop == text.len) break;

        continued = continued and std.mem.endsWith(u8, line, "\\");
        start = stop + 1;
    }

    return wide and !continued;
}

fn comments_after(tokens: []const Token, position: u32) u32 {
    assert(position < tokens.len);

    var scan = position + 1;

    while (scan < tokens.len) : (scan += 1) {
        if (significant(tokens[scan])) break;
    }

    assert(scan > position);
    assert(scan <= tokens.len);

    return scan;
}

fn patterned(source: []const u8, tokens: []const Token, gives: *ArrayType(u32)) bool {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(gives.count() <= gives.capacity());
    assert(source.len <= std.math.maxInt(u32));

    var found = false;

    for (tokens, 0..) |token, index| {
        if (token.kind != .comment) continue;

        const position: u32 = @intCast(index);
        if (!patterned_bar(source, tokens, position)) continue;

        const head = arm_headed(source, tokens, position) orelse continue;

        if (given(gives, statement_head(source, tokens, head))) found = true;
    }

    if (found) assert(!gives.empty());

    return found;
}

fn patterned_bar(source: []const u8, tokens: []const Token, position: u32) bool {
    assert(position < tokens.len);
    assert(tokens[position].kind == .comment);
    assert(source.len <= std.math.maxInt(u32));

    if (coded(tokens, position, false)) |held| {
        if (walk.text_is(tokens[held].text(source), "|")) return true;
    }

    const after = coded(tokens, position, true) orelse return false;
    const text = tokens[after].text(source);
    if (walk.text_is(text, "|")) return true;
    return walk.text_is(text, "=>");
}

fn coded(tokens: []const Token, position: u32, forward: bool) ?u32 {
    assert(position < tokens.len);

    var scan = position;

    for (0..pattern_scan_max) |_| {
        if (forward) {
            if (scan + 1 >= tokens.len) return null;

            scan += 1;
        } else {
            if (scan == 0) return null;

            scan -= 1;
        }

        if (significant(tokens[scan])) return scan;
    }

    assert(scan != position);

    return null;
}

fn arm_headed(source: []const u8, tokens: []const Token, position: u32) ?u32 {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var scan = position;
    var guard_seen = false;

    for (0..pattern_scan_max) |_| {
        if (scan == 0) return null;

        scan -= 1;

        const token = tokens[scan];
        const text = token.text(source);

        if (depth == 0) {
            if (token.kind == .block_start) break;

            const ended = walk.text_is(text, ",") or token.kind == .block_end;

            if (ended) {
                scan = block_open(tokens, scan + 1) orelse return null;

                break;
            }
        }

        if (walk.is_close(token.kind)) {
            depth += 1;
        } else if (walk.is_open(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (walk.text_is(text, "=>")) return null;

            if (walk.text_is(text, "if")) guard_seen = true;
        } else {}
    }

    assert(scan < position);

    if (guard_seen) {
        const after = coded(tokens, position, true) orelse return null;
        if (!walk.text_is(tokens[after].text(source), "=>")) return null;
    }

    return matching_head(source, tokens, scan);
}

fn matching_head(source: []const u8, tokens: []const Token, open: u32) ?u32 {
    assert(open < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var scan = open;

    for (0..pattern_scan_max) |_| {
        if (scan == 0) return null;

        scan -= 1;

        const token = tokens[scan];

        if (walk.is_close(token.kind)) {
            depth += 1;
        } else if (walk.is_open(token.kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            const text = token.text(source);
            if (walk.text_is(text, "match")) return scan;
            if (word_in(&.{ ";", "=>", "," }, text)) return null;
        } else {}
    }

    assert(scan < open);

    return null;
}

fn barred(source: []const u8, tokens: []const Token, prior: ?u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    if (prior) |held| assert(held < tokens.len);

    const held = prior orelse return false;

    assert(held < tokens.len);

    const text = tokens[held].text(source);
    if (walk.text_is(text, "|")) return true;
    return walk.text_is(text, "||");
}

fn lived(source: []const u8, tokens: []const Token, scan: u32, prior: ?u32) bool {
    assert(scan < tokens.len);

    if (!lifetimed(source, tokens[scan])) return false;
    if (prior) |held| assert(held < tokens.len);

    if (prior) |held| {
        assert(held < scan);

        if (!opens_list(tokens[held].kind)) return false;
    }

    return closes_list(tokens[named_end(tokens, scan)].kind);
}

fn opens_list(kind: Token.Kind) bool {
    if (kind != .punctuation) return false;

    const result = switch (kind.punctuation) {
        .bracket_open, .comma, .paren_open => true,
        else => false,
    };

    if (result) assert(!walk.is_close(kind));

    return result;
}

fn closes_list(kind: Token.Kind) bool {
    if (kind != .punctuation) return false;

    const result = switch (kind.punctuation) {
        .bracket_close, .comma, .paren_close => true,
        else => false,
    };

    if (result) assert(!walk.is_open(kind));

    return result;
}

fn arrowed(source: []const u8, tokens: []const Token, open: u32) bool {
    assert(open < tokens.len);
    assert(tokens[open].opens_a_group());
    assert(source.len <= std.math.maxInt(u32));

    var state: Arrowing = .{ .braced = 0, .depth = 0, .lambda = false, .prior = null };

    for (open..tokens.len) |index| {
        const scan: u32 = @intCast(index);

        switch (arrowed_step(source, tokens, scan, &state)) {
            .closed => return false,
            .found => return true,
            .pending => {},
        }

        assert(state.depth > 0);

        if (arrowed_at(source, tokens, scan, &state)) return true;

        if (significant(tokens[scan])) state.prior = scan;
    }

    return false;
}

fn arrowed_step(source: []const u8, tokens: []const Token, scan: u32, state: *Arrowing) Arrow {
    assert(scan < tokens.len);
    assert(state.braced <= state.depth);
    assert(source.len <= std.math.maxInt(u32));

    const token = tokens[scan];
    const opens = if (state.prior) |held| !walk.ends_operand(tokens[held].kind) else true;
    const inner = state.depth == 1 or (state.braced > 0 and state.depth == state.braced);

    if (walk.is_open(token.kind)) {
        state.depth += 1;

        const bracing = state.braced == 0 and token.kind == .block_start and opens and
            !barred(source, tokens, state.prior);

        if (bracing) state.braced = state.depth;

        return .pending;
    }

    if (walk.is_close(token.kind)) {
        if (state.braced == state.depth) state.braced = 0;

        state.depth -= 1;

        if (state.depth == 0) return .closed;
        return .pending;
    }

    const text = token.text(source);
    const toggles = state.depth == 1 and walk.text_is(text, "|") and (state.lambda or opens);

    if (toggles) {
        state.lambda = !state.lambda;

        return .pending;
    }

    if (!inner) return .pending;
    if (state.lambda) return .pending;
    if (arrowed_given(source, tokens, scan, state.prior)) return .found;
    return .pending;
}

fn arrowed_given(source: []const u8, tokens: []const Token, scan: u32, prior: ?u32) bool {
    assert(scan < tokens.len);
    if (prior) |held| assert(held < scan);
    assert(source.len <= std.math.maxInt(u32));

    const text = tokens[scan].text(source);
    if (walk.text_is(text, "=>")) return true;
    if (walk.text_is(text, ":")) return true;
    if (lived(source, tokens, scan, prior)) return true;
    if (loned(source, tokens, scan, prior)) return true;
    if (walk.text_is(text, "@")) return true;
    if (!walk.text_is(text, "fn")) return false;
    return !item_bodied(tokens, scan, @intCast(tokens.len));
}

fn arrowed_at(source: []const u8, tokens: []const Token, scan: u32, state: *const Arrowing) bool {
    assert(scan < tokens.len);
    assert(state.depth > 0);

    if (state.lambda) return false;
    if (!walk.text_is(tokens[scan].text(source), "@")) return false;

    const held = state.prior orelse return false;
    return walk.is_open(tokens[held].kind);
}

fn loned(source: []const u8, tokens: []const Token, scan: u32, prior: ?u32) bool {
    assert(scan < tokens.len);
    if (prior) |held| assert(held < tokens.len);

    const token = tokens[scan];
    if (token.kind != .punctuation) return false;
    if (word_in(&lone_keeps, token.text(source))) return false;

    const held = prior orelse return false;

    assert(held < scan);

    if (!opens_list(tokens[held].kind)) return false;
    return closes_list(tokens[settled(tokens, scan + 1)].kind);
}

fn unparsed(source: []const u8, tokens: []const Token, open: u32) bool {
    assert(open < tokens.len);
    assert(tokens[open].opens_a_group());

    if (tokens[open].kind == .block_start) return false;
    assert(source.len <= std.math.maxInt(u32));

    const close = group_shut(tokens, open) orelse return false;
    var state: Argued = .fresh;
    var scan = settled(tokens, open + 1);

    for (0..tokens.len) |_| {
        if (scan >= close) return false;

        switch (unparsed_step(source, tokens, scan, close, &state)) {
            .abstained => return false,
            .failed => return true,
            .next => |next| {
                assert(next > scan);

                scan = next;
            },
        }
    }

    return false;
}

fn unparsed_step(
    source: []const u8,
    tokens: []const Token,
    scan: u32,
    close: u32,
    state: *Argued,
) Parsing {
    assert(scan < close);
    assert(close < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    const token = tokens[scan];
    const text = token.text(source);
    const after = settled(tokens, scan + 1);

    if (walk.is_open(token.kind)) {
        const shut = group_shut(tokens, scan) orelse return .abstained;
        if (shut >= close) return .abstained;

        state.ended = true;

        return .{ .next = settled(tokens, shut + 1) };
    }

    switch (token.kind) {
        .identifier, .number, .string => {
            if (std.mem.startsWith(u8, text, "'")) return .abstained;
            if (state.ended) return .failed;

            if (token.kind != .identifier) state.typed = false;

            state.ended = true;

            return .{ .next = after };
        },
        .keyword => {
            if (!word_in(&literal_keywords, text)) return .abstained;
            if (state.ended) return .failed;

            state.ended = true;

            return .{ .next = after };
        },
        .punctuation => return unparsed_mark(source, tokens, scan, close, state),
        .block_end, .block_start, .comment, .newline => return .abstained,
    }
}

fn unparsed_mark(
    source: []const u8,
    tokens: []const Token,
    scan: u32,
    close: u32,
    state: *Argued,
) Parsing {
    assert(scan < close);
    assert(tokens[scan].kind == .punctuation);
    assert(source.len <= std.math.maxInt(u32));

    const text = tokens[scan].text(source);
    const after = settled(tokens, scan + 1);
    const ended = state.ended;

    state.ended = false;

    if (word_in(&.{ ",", ";" }, text)) {
        state.* = .fresh;

        return .{ .next = after };
    }

    if (tokens[scan].kind.eql(.{ .punctuation = .ampersand_double })) {
        if (ended) state.compared = 0;

        return .{ .next = after };
    }

    if (walk.text_is(text, "...")) return .failed;

    if (word_in(&.{ "<", ">", "<=", ">=", "==", "!=" }, text)) {
        return unparsed_compared(source, tokens, scan, close, ended, state);
    }

    if (word_in(&.{ "&&", "||", "=", "..", "..=" }, text)) {
        const chains = ended or word_in(&.{ "..", "&&" }, text);
        if (!chains) return .abstained;

        state.compared = 0;

        return .{ .next = after };
    }

    if (walk.text_is(text, "::")) return unparsed_pathed(source, tokens, scan, close, state);

    if (walk.text_is(text, "?")) {
        state.ended = ended;
        state.typed = false;

        return if (ended) .{ .next = after } else .failed;
    }

    if (walk.text_is(text, ".")) {
        state.typed = false;

        return if (ended) .{ .next = after } else .abstained;
    }

    if (!ended) {
        if (word_in(&.{ "-", "!" }, text)) state.typed = false;
        if (walk.text_is(text, "|")) return .abstained;
    }

    if (word_in(&.{ "!", "%", "&", "*", "+", "-", "/", "<<", ">>", "^", "|" }, text)) {
        return .{ .next = after };
    }

    return .abstained;
}

fn unparsed_compared(
    source: []const u8,
    tokens: []const Token,
    scan: u32,
    close: u32,
    ended: bool,
    state: *Argued,
) Parsing {
    assert(scan < close);
    assert(!state.ended);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    if (!ended) {
        if (!walk.text_is(tokens[scan].text(source), "<")) return .failed;
        return unparsed_qualified(source, tokens, scan, close, state);
    }

    const opened = state.compared;

    state.compared += 1;

    if (state.compared > 1) {
        if (!state.typed) return .failed;
    }

    const after = settled(tokens, scan + 1);
    const ends = after >= close or word_in(&.{ ",", ";" }, tokens[after].text(source));
    const typed = walk.text_is(tokens[scan].text(source), ">") and opened > 0 and state.typed;

    if (ends) {
        if (!typed) return .failed;
    }

    return .{ .next = after };
}

fn unparsed_pathed(
    source: []const u8,
    tokens: []const Token,
    scan: u32,
    close: u32,
    state: *Argued,
) Parsing {
    assert(scan < close);
    assert(walk.text_is(tokens[scan].text(source), "::"));

    const after = settled(tokens, scan + 1);
    if (after >= close) return .{ .next = after };
    if (!walk.text_is(tokens[after].text(source), "<")) return .{ .next = after };

    const shut = angle_shut(source, tokens, after, close) orelse return .abstained;

    state.ended = true;

    return .{ .next = settled(tokens, shut + 1) };
}

fn unparsed_qualified(
    source: []const u8,
    tokens: []const Token,
    scan: u32,
    close: u32,
    state: *Argued,
) Parsing {
    assert(scan < close);
    assert(walk.text_is(tokens[scan].text(source), "<"));

    const shut = angle_shut(source, tokens, scan, close) orelse return .abstained;
    const after = settled(tokens, shut + 1);
    if (after >= close) return .failed;
    if (!walk.text_is(tokens[after].text(source), "::")) return .failed;

    state.ended = false;

    return .{ .next = settled(tokens, after + 1) };
}

fn group_shut(tokens: []const Token, open: u32) ?u32 {
    assert(open < tokens.len);
    assert(walk.is_open(tokens[open].kind));

    var depth: u32 = 0;

    for (tokens[open..], open..) |token, index| {
        if (walk.is_open(token.kind)) depth += 1;
        if (!walk.is_close(token.kind)) continue;

        depth -= 1;

        if (depth == 0) {
            assert(index <= tokens.len);

            return @intCast(index);
        }
    }

    return null;
}

fn angle_shut(source: []const u8, tokens: []const Token, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var angles: u32 = 0;
    var scan = open;

    while (scan < close) : (scan += 1) {
        const token = tokens[scan];

        if (walk.is_open(token.kind)) {
            scan = group_shut(tokens, scan) orelse return null;

            continue;
        }

        const text = token.text(source);

        if (walk.text_is(text, "<")) angles += 1;
        if (walk.text_is(text, ">")) angles -|= 1;
        if (walk.text_is(text, ">>")) angles -|= 2;
        if (angles == 0) return scan;
    }

    return null;
}

fn lifetimed(source: []const u8, token: Token) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(token.end() <= source.len);

    const text = token.text(source);
    if (!std.mem.startsWith(u8, text, "'")) return false;
    if (token.kind == .identifier) return true;
    if (token.kind != .string) return false;
    if (text.len < 4) return false;
    if (!std.mem.endsWith(u8, text, "'")) return false;
    if (text[1] == '\\') return false;

    var points: u32 = 0;

    for (text[1 .. text.len - 1]) |byte| {
        if (byte & 0xC0 != 0x80) points += 1;
    }

    assert(points <= text.len - 2);

    return points > 1;
}

fn named_end(tokens: []const Token, apostrophe: u32) u32 {
    assert(apostrophe < tokens.len);

    const held = settled(tokens, apostrophe + 1);

    if (tokens[held].kind != .identifier) {
        assert(held <= tokens.len);

        return held;
    }

    const result = settled(tokens, held + 1);

    assert(result > apostrophe);

    return result;
}

fn item_bodied(tokens: []const Token, head: u32, stop: u32) bool {
    assert(head < stop);
    assert(stop <= tokens.len);

    var depth: u32 = 0;
    var code_last = head;
    var scan = head;

    while (scan < stop) : (scan += 1) {
        const token = tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) break;

            depth -= 1;
        } else if (depth == 0) {
            if (token.is_punctuation(.comma)) break;
            if (token.is_punctuation(.semicolon)) break;
        } else {}

        if (significant(token)) code_last = scan;
    }

    assert(code_last >= head);

    if (tokens[code_last].kind == .block_end) return true;
    return tokens[code_last].is_punctuation(.semicolon);
}

fn headed(source: []const u8, tokens: []const Token, bang: u32) u32 {
    assert(bang < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var head = statement_head(source, tokens, bang);

    for (0..give_climb_max) |_| {
        if (head >= bang) return head;
        if (!walk.text_is(tokens[head].text(source), "#")) return head;

        var scan = head;

        while (scan < bang) : (scan += 1) {
            if (tokens[scan].is_punctuation(.bracket_close)) break;
        }

        assert(scan <= bang);

        head = settled(tokens, scan + 1);
    }

    return head;
}

fn banged(source: []const u8, tokens: []const Token, position: u32) bool {
    assert(position < tokens.len);

    if (!walk.text_is(tokens[position].text(source), "!")) return false;

    const held = behind(tokens, position) orelse return false;
    const kind = tokens[held].kind;
    const named = kind == .identifier or kind == .keyword;

    assert(held < position);

    if (!named) return false;
    return tokens[held].end() == tokens[position].offset;
}

fn give_macros(
    source: []const u8,
    tokens: []const Token,
    gives: *ArrayType(u32),
    macros: *ArrayType(u32),
    opaques: *ArrayType(u32),
) bool {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(macros.empty());
    assert(opaques.empty());
    assert(source.len <= std.math.maxInt(u32));

    var found = false;

    for (0..tokens.len) |index| {
        const position: u32 = @intCast(index);
        if (!banged(source, tokens, position)) continue;

        const open = settled(tokens, position + 1);
        if (open == tokens.len) continue;

        assert(open < tokens.len);

        if (!tokens[open].opens_a_group()) continue;

        if (!arrowed(source, tokens, open)) {
            if (!unparsed(source, tokens, open)) continue;
        }

        const head = headed(source, tokens, position);

        if (!macro_headed(source, tokens, head, position)) {
            _ = given(opaques, open);

            continue;
        }

        _ = given(macros, head);

        if (given(gives, head)) found = true;
    }

    if (found) assert(!gives.empty());

    return found;
}

fn macro_headed(source: []const u8, tokens: []const Token, head: u32, bang: u32) bool {
    assert(bang < tokens.len);

    if (head >= bang) return false;
    assert(source.len <= std.math.maxInt(u32));

    for (tokens[head..bang]) |token| {
        if (!significant(token)) continue;
        if (token.kind == .identifier) continue;

        const text = token.text(source);
        if (!word_in(&path_words, text)) return false;
    }

    return true;
}

fn linked_below(printed: []const u8, stop: u32) bool {
    assert(stop < printed.len);
    assert(printed[stop] == '\n');

    var scan = stop + 1;

    while (scan < printed.len) : (scan += 1) {
        const blank = printed[scan] == ' ' or printed[scan] == '\t';
        if (!blank) break;
    }

    if (scan >= printed.len) return false;
    return printed[scan] == '.';
}

fn given(gives: *ArrayType(u32), head: u32) bool {
    const held = gives.const_slice();
    var low: u32 = 0;
    var high: u32 = @intCast(held.len);

    while (low < high) {
        const middle = low + @divFloor(high - low, 2);

        if (held[middle] < head) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    if (low < held.len) {
        if (held[low] == head) return false;
    }

    if (gives.full()) return false;

    gives.shift_tail(.{ .from = low, .to = low + 1 });
    gives.slice()[low] = head;

    if (low > 0) assert(gives.get(low - 1) < head);
    if (low + 1 < gives.count()) assert(gives.get(low + 1) > head);

    return true;
}

fn blanked(out: *Buffer) FormatterError!void {
    out.clear();
    out.push_byte('\n') catch return error.OutputExhausted;

    assert(out.count() == 1);
}

fn copied(source: []const u8, out: *Buffer) FormatterError!void {
    assert(source.len <= std.math.maxInt(u32));

    out.clear();
    out.push(source) catch return error.OutputExhausted;

    assert(out.count() == source.len);
}

fn quoted(source: []const u8, position: u32, tokens: []const Token) bool {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    const token = tokens[position];
    const text = token.text(source);

    if (token.kind != .string) return false;
    if (std.mem.startsWith(u8, text, "\"")) return true;
    if (std.mem.startsWith(u8, text, "r\"")) return true;
    return std.mem.startsWith(u8, text, "r#");
}

fn columned(source: []const u8, tokens: []const Token, head: u32) u32 {
    assert(head < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    const offset = @min(tokens[head].offset, @as(u32, @intCast(source.len)));
    var start = offset;

    while (start > 0) : (start -= 1) {
        if (source[start - 1] == '\n') break;
    }

    assert(start <= offset);

    return walk.columns(source, start, offset);
}

fn ruled_head(source: []const u8, tokens: []const Token, head: u32) bool {
    assert(head < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var scan = head;

    for (0..macro_rule_max) |_| {
        const text = tokens[scan].text(source);
        if (walk.text_is(text, "macro_rules")) return true;
        if (walk.text_is(text, "macro")) return true;
        if (!word_in(&macro_heads, text)) return false;

        scan = settled(tokens, scan + 1);
    }

    assert(scan >= head);

    return false;
}

fn macro_ruled(source: []const u8, tokens: []const Token, position: u32) ?u32 {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var scan = position;

    for (0..give_climb_max) |_| {
        const open = block_open(tokens, scan) orelse return null;
        const head = statement_head(source, tokens, open);

        assert(open < scan);

        if (ruled_head(source, tokens, head)) return head;

        scan = open;
    }

    return null;
}

fn marks(
    source: []const u8,
    tokens: []const Token,
    printed: []const u8,
    lines: []const u32,
    widths: brace.Widths,
    gives: *ArrayType(u32),
) bool {
    assert(printed.len <= std.math.maxInt(u32));
    assert(widths.line > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(lines.len <= std.math.maxInt(u32));

    var found = false;
    var index: u32 = 0;
    var start: u32 = 0;

    for (printed, 0..) |byte, at| {
        if (byte != '\n') continue;

        const stop: u32 = @intCast(at);
        const line = printed[start..stop];

        start = stop + 1;
        index += 1;

        const linked = std.mem.endsWith(u8, line, "\"") and linked_below(printed, stop);
        const owed: u32 = @intFromBool(linked);
        const spread = walk.columns(printed, stop -| @as(u32, @intCast(line.len)), stop) + owed;
        if (spread <= widths.line) continue;
        if (commented_line(line)) continue;
        if (index - 1 >= lines.len) continue;

        const position = token_at(tokens, lines[index - 1]) orelse continue;

        if (marks_line(source, tokens, position, owed, widths, gives)) found = true;
    }

    if (found) assert(!gives.empty());

    return found;
}

fn marks_line(
    source: []const u8,
    tokens: []const Token,
    position: u32,
    owed: u32,
    widths: brace.Widths,
    gives: *ArrayType(u32),
) bool {
    assert(position < tokens.len);
    assert(owed <= 1);
    assert(source.len <= std.math.maxInt(u32));
    assert(widths.line > 0);

    if (macro_ruled(source, tokens, position)) |ruled| return given(gives, ruled);

    if (!quoted(source, position, tokens)) {
        const token = tokens[position];
        const owner = stated_head(source, tokens, position);
        const spelled = walk.columns(source, token.offset, token.end());

        if (columned(source, tokens, owner) + widths.indent + spelled > widths.line) {
            return given(gives, owner);
        }
    }

    if (owed > 0) return given(gives, stated_head(source, tokens, position));

    const head = chained_head(source, tokens, position) orelse return false;
    return given(gives, head);
}

fn chained_head(source: []const u8, tokens: []const Token, position: u32) ?u32 {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var head = stated_head(source, tokens, position);
    var found: ?u32 = if (guarded(source, tokens, position, head)) head else null;

    for (0..give_climb_max) |_| {
        const open = block_open(tokens, head) orelse return found;
        const owner = stated_head(source, tokens, open);

        assert(open < tokens.len);

        if (item_headed(source, tokens, owner)) return found;

        if (guarded(source, tokens, head, owner)) found = owner;

        head = owner;
    }

    return found;
}

fn owes(kind: Kind, parent: Kind) bool {
    assert(kind.is_node());
    assert(parent.is_node());

    if (parent != .block) return false;

    return switch (kind) {
        .expr_break, .expr_continue, .expr_return => true,
        else => false,
    };
}

fn bounds(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .expr_if, .local => true,
        else => false,
    };
}

fn lambda(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .expr_closure;
}

fn lasts(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .expr_call, .expr_method_call => true,
        else => false,
    };
}

fn attributes(kind: Kind, parent: Kind, grand: ?Kind) bool {
    assert(kind.is_node());
    assert(parent.is_node());

    if (kind != .attribute) return false;
    if (grand == .block) return true;

    return switch (parent) {
        .arm,
        .block,
        .field_value,
        .file,
        .foreign_item_fn,
        .foreign_item_macro,
        .foreign_item_static,
        .foreign_item_type,
        .impl_item_const,
        .impl_item_fn,
        .impl_item_macro,
        .impl_item_type,
        .item_const,
        .item_enum,
        .item_extern_crate,
        .item_fn,
        .item_foreign_mod,
        .item_impl,
        .item_macro,
        .item_mod,
        .item_static,
        .item_struct,
        .item_trait,
        .item_trait_alias,
        .item_type,
        .item_union,
        .item_use,
        .trait_item_const,
        .trait_item_fn,
        .trait_item_macro,
        .trait_item_type,
        .variant,
        => true,
        .field => grand == .fields_named,
        else => false,
    };
}

fn bodies(kind: Kind) u32 {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .expr_call, .expr_macro, .expr_tuple => policy.call_width,
        .expr_method_call => policy.chain_width,
        .expr_if => policy.branch_width,
        .expr_struct => policy.literal_width,
        else => 0,
    };
}

fn argued(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .expr_call, .expr_macro, .expr_struct => true,
        else => false,
    };
}

fn chained(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .expr_method_call;
}

fn arms(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .arm;
}

fn items(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .field, .variant => true,
        else => false,
    };
}

fn lined(kind: Kind, parent: Kind) bool {
    assert(kind.is_node());
    assert(parent.is_node());

    if (kind == .item_enum) return true;
    if (kind != .fields_named) return false;

    return switch (parent) {
        .item_struct, .item_union => true,
        else => false,
    };
}

fn compares(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .expr_binary;
}

fn flattens(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .block,
        .expr_array,
        .expr_block,
        .expr_call,
        .expr_closure,
        .expr_macro,
        .expr_match,
        .expr_method_call,
        .expr_struct,
        .expr_tuple,
        .macro,
        => true,
        else => false,
    };
}

fn keeps(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .stmt_macro;
}

fn operands(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .expr_cast or kind == .expr_index;
}

fn forces(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .expr_for_loop, .expr_if, .expr_loop, .expr_while => true,
        else => false,
    };
}

fn wraps(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .block,
        .expr_async,
        .expr_block,
        .expr_const,
        .expr_for_loop,
        .expr_loop,
        .expr_match,
        .expr_struct,
        .expr_try_block,
        .expr_unsafe,
        .expr_while,
        => false,
        else => true,
    };
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

    if (unclosed(input)) return true;
    return !brace.balanced(input.source, input.tokens);
}

fn unclosed(input: *const Input) bool {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    for (input.tokens) |token| {
        const held = if (token.kind == .string) unsuffixed(input.source, token) else token;
        if (!brace.closed(input.source, &.{held}, true, true)) return true;
    }

    return false;
}

fn unsuffixed(source: []const u8, token: Token) Token {
    assert(token.kind == .string);
    assert(token.length > 0);
    assert(source.len <= std.math.maxInt(u32));

    const text = token.text(source);
    var length = token.length;

    while (length > 1) : (length -= 1) {
        const byte = text[length - 1];

        if (byte < 0x80) {
            if (!is_identifier_part(byte)) break;
        }
    }

    assert(length > 0);
    assert(length <= token.length);

    return .{ .offset = token.offset, .length = length, .kind = token.kind, .code = token.code };
}
