const std = @import("std");
const assert = std.debug.assert;
const Span = @import("../../stdx/bounded/span.zig");

pub const Diagnostic = struct {
    kind: Kind,
    name: Span,
    span: Span,

    pub const Kind = enum {
        source_too_large,
        unclosed_element,
        unexpected_close_tag,
        unterminated_attribute_value,
        unterminated_template_comment,
        unterminated_template_tag,
        unterminated_template_variable,

        pub fn title(kind: Kind) []const u8 {
            const held = switch (kind) {
                .source_too_large => "SourceTooLarge",
                .unclosed_element => "UnclosedElement",
                .unexpected_close_tag => "UnexpectedCloseTag",
                .unterminated_attribute_value => "UnterminatedAttributeValue",
                .unterminated_template_comment => "UnterminatedTemplateComment",
                .unterminated_template_tag => "UnterminatedTemplateTag",
                .unterminated_template_variable => "UnterminatedTemplateVariable",
            };

            assert(held.len > 0);
            assert(std.ascii.isUpper(held[0]));

            return held;
        }
    };
};
