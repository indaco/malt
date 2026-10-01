//! malt - stdout writer invariant
//!
//! `ctx.stdout` can be a regular file shared with earlier writers (`>`,
//! `>>`, `exec >log`). A positional `File.Writer` starts at offset 0 and
//! pwrite-clobbers it, so CLI commands must build theirs streaming.

const std = @import("std");
const testing = std.testing;
const test_io = @import("test_io");

test "no CLI command builds a positional writer on ctx.stdout" {
    const alloc = testing.allocator;
    var dir = try test_io.cwd().openDir(std.Options.debug_io, "src/cli", .{ .iterate = true });
    defer dir.close(std.Options.debug_io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var violations: std.ArrayList(u8) = .empty;
    defer violations.deinit(alloc);

    while (try walker.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const f = try entry.dir.openFile(std.Options.debug_io, entry.basename, .{});
        defer f.close(std.Options.debug_io);
        const src = try test_io.readFileToEndAlloc(f, alloc, 4 * 1024 * 1024);
        defer alloc.free(src);

        var it = std.mem.splitScalar(u8, src, '\n');
        var lineno: usize = 0;
        while (it.next()) |line| {
            lineno += 1;
            // Catches `ctx.stdout.writer(` and a local alias such as
            // `stdout.writer(` / `stdout_file.writer(`.
            if (std.mem.indexOf(u8, line, "stdout.writer(") == null and
                std.mem.indexOf(u8, line, "stdout_file.writer(") == null) continue;
            const msg = try std.fmt.allocPrint(alloc, "src/cli/{s}:{d}: {s}\n", .{ entry.path, lineno, line });
            defer alloc.free(msg);
            try violations.appendSlice(alloc, msg);
        }
    }

    if (violations.items.len != 0) {
        std.debug.print("positional stdout writer (use writerStreaming):\n{s}\n", .{violations.items});
        return error.TestUnexpectedResult;
    }
}
