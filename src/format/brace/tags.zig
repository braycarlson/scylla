const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const brace = @import("../brace.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;
const tag_scan_max: u32 = 1 << 16;

const Level = struct {
    closing: bool,
    elements: u32,
    tagging: bool,
};

const Scan = struct {
    angles: u32 = 0,
    braces: u32 = 0,
    depth: u32 = 1,
    levels: [core.jsx_depth_max]Level = undefined,
    valued: bool = false,

    const Step = enum { done, more };

    fn step(scan: *Scan, emitter: *const Emitter, token: Token) ?Step {
        assert(scan.depth > 0);
        assert(scan.depth <= core.jsx_depth_max);
        assert(token.length <= std.math.maxInt(u32) - token.offset);

        const opens = token.kind == .block_start or walk.substituting(emitter.source, token);
        const text = token.text(emitter.source);
        const angled = walk.text_is(text, "<");
        const slashed = walk.text_is(text, "</");
        const level = &scan.levels[scan.depth - 1];
        const after_equal = scan.valued;
        const bracing = scan.braces > 0 or opens;
        const tagged = angled or slashed;
        const attributed = angled and after_equal and scan.angles == 0;
        const angling = angled or scan.angles > 0;

        scan.valued = walk.text_is(text, "=");

        if (bracing) {
            scan.braces = nested(scan.braces, opens, token.kind == .block_end);

            return .more;
        }

        if (!level.tagging) {
            if (tagged) {
                level.closing = slashed;
                level.tagging = true;
            }

            return .more;
        }

        if (slashed) return null;

        if (attributed) {
            if (scan.depth == core.jsx_depth_max) return null;

            scan.levels[scan.depth] = .{ .closing = false, .elements = 0, .tagging = true };
            scan.depth += 1;

            return .more;
        }

        if (angling) {
            scan.angles = nested(scan.angles, angled, walk.text_is(text, ">"));

            return .more;
        }

        return scan.closed(text);
    }

    fn closed(scan: *Scan, text: []const u8) ?Step {
        assert(text.len <= std.math.maxInt(u32));

        const level = &scan.levels[scan.depth - 1];

        assert(level.tagging);
        assert(scan.angles == 0);

        if (walk.text_is(text, ">")) {
            level.tagging = false;
            level.elements = elements_counted(level.elements, level.closing) orelse return null;
        } else if (walk.text_is(text, "/>")) {
            level.tagging = false;
        } else {}

        if (level.tagging) return .more;
        if (level.elements > 0) return .more;
        if (scan.depth == 1) return .done;

        scan.depth -= 1;

        return .more;
    }
};

pub fn body_close(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emit.roled(emitter, position, brace.role_jsx));

    const close = scanned(emitter, position);

    if (close) |held| assert(held >= position);

    return close;
}

fn elements_counted(elements: u32, closing: bool) ?u32 {
    assert(elements < std.math.maxInt(u32));

    if (closing) {
        if (elements == 0) return null;
        assert(elements - 1 < std.math.maxInt(u32));

        return elements - 1;
    }

    assert(elements + 1 < std.math.maxInt(u32));

    return elements + 1;
}

fn nested(depth: u32, opens: bool, closes: bool) u32 {
    assert(depth < std.math.maxInt(u32));

    if (opens) {
        assert(depth + 1 < std.math.maxInt(u32));

        return depth + 1;
    }

    if (closes) {
        assert(depth > 0);

        return depth - 1;
    }

    return depth;
}

fn scanned(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emit.roled(emitter, position, brace.role_jsx));

    var scanner: Scan = .{};
    var scan = position;

    scanner.levels[0] = .{ .closing = false, .elements = 0, .tagging = false };

    for (0..tag_scan_max) |_| {
        if (scan >= emitter.count) return null;

        const token = emitter.tokens[scan];

        scan += 1;

        switch (scanner.step(emitter, token) orelse return null) {
            .done => {
                assert(scan > 0);

                return scan - 1;
            },
            .more => {},
        }
    }

    return null;
}
