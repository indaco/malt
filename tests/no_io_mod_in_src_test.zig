//! Pin test: production-shaped trees (src/, bench/) contain no
//! `fs_compat` references and no `ui/io.zig` imports. The retired
//! test-shape modules must stay retired.

const std = @import("std");
const testing = std.testing;
const test_io = @import("test_io");

const forbidden_substrings = [_][]const u8{
    "fs_compat",
    "io_mod",
    "@import(\"../ui/io.zig\")",
    "@import(\"../../ui/io.zig\")",
    "@import(\"ui/io.zig\")",
};

const scanned_roots = [_][]const u8{ "src", "bench" };

test "production trees contain no references to retired test-shape modules" {
    const io = std.Options.debug_io;

    var failures: std.ArrayList([]const u8) = .empty;
    defer {
        for (failures.items) |s| testing.allocator.free(s);
        failures.deinit(testing.allocator);
    }

    for (scanned_roots) |root| {
        try scanRoot(io, root, &failures);
    }

    if (failures.items.len != 0) {
        for (failures.items) |f| std.debug.print("{s}\n", .{f});
        return error.ForbiddenSubstringFound;
    }
}

fn scanRoot(io: std.Io, root: []const u8, failures: *std.ArrayList([]const u8)) !void {
    var dir = try test_io.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const file = try dir.openFile(io, entry.path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const content = try testing.allocator.alloc(u8, @intCast(stat.size));
        defer testing.allocator.free(content);
        _ = try file.readPositionalAll(io, content, 0);

        for (forbidden_substrings) |needle| {
            if (std.mem.indexOf(u8, content, needle)) |_| {
                const msg = try std.fmt.allocPrint(
                    testing.allocator,
                    "{s}/{s} contains forbidden substring \"{s}\"",
                    .{ root, entry.path, needle },
                );
                try failures.append(testing.allocator, msg);
            }
        }
    }
}
