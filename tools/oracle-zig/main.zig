const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(arena);

    if (arguments.len != 3) {
        std.debug.print("usage: oracle-zig <source root> <destination root>\n", .{});
        std.process.exit(2);
    }

    var root = try std.Io.Dir.cwd().openDir(io, arguments[1], .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(arena);
    defer walker.deinit();

    var skipped: usize = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const source = root.readFileAllocOptions(
            io,
            entry.path,
            arena,
            .limited(1 << 26),
            .of(u8),
            0,
        ) catch {
            skipped += 1;
            continue;
        };

        var ast = std.zig.Ast.parse(arena, source, .zig) catch {
            skipped += 1;
            continue;
        };

        if (ast.errors.len > 0) {
            skipped += 1;
            continue;
        }

        var body: std.ArrayList(u8) = .empty;

        try body.appendSlice(arena, "{\"ast\":[");
        try body.print(arena, "[\"root\",0,{d}]", .{source.len});

        var index: u32 = 1;

        while (index < ast.nodes.len) : (index += 1) {
            const node: std.zig.Ast.Node.Index = @enumFromInt(index);
            const tag = ast.nodeTag(node);
            const first = ast.firstToken(node);
            const last = ast.lastToken(node);
            const start = ast.tokenStart(first);
            const end = ast.tokenStart(last) + ast.tokenSlice(last).len;

            if (end < start) continue;

            try body.print(arena, ",[\"{s}\",{d},{d}]", .{ @tagName(tag), start, end });
        }

        const relative = try arena.dupe(u8, entry.path);

        for (relative) |*byte| {
            if (byte.* == '\\') byte.* = '/';
        }

        try body.print(arena, "],\"broken\":false,\"path\":\"{s}\"}}\n", .{relative});

        const target = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ arguments[2], relative });

        if (std.fs.path.dirname(target)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = body.items });
    }

    if (skipped > 0) {
        std.debug.print("skipped {d} files\n", .{skipped});
    }
}
