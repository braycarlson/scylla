const std = @import("std");
const assert = std.debug.assert;
const Edit = Report.Row.Edit;
const FileID = @import("../../stdx/file_id.zig").FileID;
const Format = @import("../report.zig").Format;
const LineIndex = @import("../../text/line_index.zig").LineIndex;
const Registry = @import("../rule.zig").Registry;
const Related = Report.Row.Related;
const Report = @import("../report.zig").Report;
const Row = Report.Row;
const Rule = @import("../rule.zig").Rule;
const StaticAllocator = @import("../../stdx/static_allocator.zig");
const Terminal = @import("../../cli/terminal.zig");
const Text = Report.Text;
const Tool = Report.Tool;
pub const out_bytes_max: u32 = 1 << 14;
pub const page = "<div>\n\t{{ block.super }}\n</div>\n";
pub const view = "def view(request):\n    return render(request, 'page.html')\n";

pub const tool: Tool = .{
    .information_uri = "https://example.invalid/tool",
    .name = "tool",
    .rule_uri_prefix = "https://example.invalid/rules/",
    .rule_uri_suffix = ".md",
    .version = "1.2.3",
};

pub const Fixture = struct {
    page_lines: LineIndex,
    view_lines: LineIndex,

    pub fn init(gpa: std.mem.Allocator) !Fixture {
        var page_lines = try LineIndex.init(gpa, 16);
        errdefer page_lines.deinit(gpa);

        var view_lines = try LineIndex.init(gpa, 16);
        errdefer view_lines.deinit(gpa);

        try page_lines.build(page);
        try view_lines.build(view);

        assert(page_lines.count() > 0);
        assert(view_lines.count() > 0);

        return .{ .page_lines = page_lines, .view_lines = view_lines };
    }

    pub fn deinit(fixture: *Fixture, gpa: std.mem.Allocator) void {
        fixture.page_lines.deinit(gpa);
        fixture.view_lines.deinit(gpa);
    }

    pub fn count(fixture: *const Fixture) u32 {
        _ = fixture;

        comptime assert(rules.len == 2);

        return 2;
    }

    pub fn edit(fixture: *const Fixture, index: u32, at: u32) Edit {
        _ = fixture;

        assert(index == 0);
        assert(at == 0);

        return .{
            .replacement = "{% block body %}{{ block.super }}{% endblock %}",
            .span = .{ .offset = 7, .length = 17 },
        };
    }

    pub fn edit_count(fixture: *const Fixture, index: u32) u32 {
        assert(index < fixture.count());

        return @intFromBool(index == 0);
    }

    pub fn related(fixture: *const Fixture, index: u32, at: u32) Related {
        _ = fixture;

        assert(index == 1);
        assert(at == 0);

        return .{
            .file = FileID.of(1),
            .message = "rendered here",
            .span = .{ .offset = 30, .length = 6 },
        };
    }

    pub fn related_count(fixture: *const Fixture, index: u32) u32 {
        assert(index < fixture.count());

        return @intFromBool(index == 1);
    }

    pub fn row(fixture: *const Fixture, index: u32) Row {
        assert(index < fixture.count());

        if (index == 0) {
            return .{
                .code = "TP001",
                .file = FileID.of(0),
                .fix = .{
                    .applicability = .unsafe,
                    .title = "Wrap the super call in a block",
                },
                .message = "`block.super` outside any block",
                .rule = "template/super-outside-block",
                .severity = .warning,
                .span = .{ .offset = 7, .length = 17 },
            };
        }

        return .{
            .code = "TP002",
            .file = FileID.of(0),
            .fix = null,
            .message = "`div` is never closed % of the time",
            .rule = "template/unclosed",
            .severity = .@"error",
            .span = .{ .offset = 0, .length = 5 },
        };
    }

    pub fn text(fixture: *const Fixture, file: FileID) Text {
        assert(file.index() <= 1);

        if (file == FileID.of(0)) {
            return .{
                .lines = &fixture.page_lines,
                .path = "templates/page.html",
                .source = page,
            };
        }

        return .{ .lines = &fixture.view_lines, .path = "app/views.py", .source = view };
    }
};

pub const rules = [_]Rule{
    rule_of("TP001", "template/super-outside-block", "Checks for a super call outside any block."),
    rule_of("TP002", "template/unclosed", "Checks for an element that is never closed."),
};

pub fn rule_of(code: []const u8, name: []const u8, summary: []const u8) Rule {
    assert(code.len > 0);
    assert(name.len > 0);
    assert(summary.len <= std.math.maxInt(u32));

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
        .summary = summary,
        .url = "",
    };
}

pub fn rendered(gpa: std.mem.Allocator, format: Format) ![]u8 {
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var registry: Registry = try .init(gpa, rules.len);
    defer registry.deinit(gpa);

    for (&rules) |*item| registry.register(item);

    assert(registry.count() == rules.len);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    const static = static_allocator.allocator();
    const sizes: Report.Capacity = .{ .body_bytes_max = out_bytes_max, .line_count_max = 64 };
    var held = try Report.init(static, sizes, &.{ .format = format, .tool = tool });
    defer held.deinit(static);

    var out = try Terminal.init(static, &.{ .buffer_bytes_max = out_bytes_max, .target = .memory });
    defer out.deinit(static);

    static_allocator.transition_from_init_to_static();
    held.begin(&out);
    held.render_file(Fixture, &out, &fixture);
    held.end(&out, &registry);
    static_allocator.transition_from_static_to_deinit();

    try std.testing.expect(!out.is_truncated());
    try std.testing.expect(!out.is_failed());

    return gpa.dupe(u8, out.contents());
}
