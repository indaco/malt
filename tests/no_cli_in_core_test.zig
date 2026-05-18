//! Pin test: no `core/*` file may import `cli/*`.

const std = @import("std");
const testing = std.testing;

const test_io = @import("test_io");

const scanned_root = "src/core";
const import_prefix = "@import(\"";

test "core/* files do not import cli/*" {
    const io = std.Options.debug_io;

    var failures: std.ArrayList([]const u8) = .empty;
    defer {
        for (failures.items) |s| testing.allocator.free(s);
        failures.deinit(testing.allocator);
    }

    try scanRoot(io, scanned_root, &failures);

    if (failures.items.len != 0) {
        for (failures.items) |f| std.debug.print("{s}\n", .{f});
        return error.CoreImportsCli;
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

        try scanContent(root, entry.path, content, failures);
    }
}

fn scanContent(
    root: []const u8,
    rel_path: []const u8,
    content: []const u8,
    failures: *std.ArrayList([]const u8),
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, import_prefix)) |start| {
        const path_start = start + import_prefix.len;
        const end = std.mem.indexOfScalarPos(u8, content, path_start, '"') orelse break;
        const import_path = content[path_start..end];
        cursor = end + 1;

        if (resolvesIntoCli(import_path)) {
            const msg = try std.fmt.allocPrint(
                testing.allocator,
                "{s}/{s} imports {s}",
                .{ root, rel_path, import_path },
            );
            try failures.append(testing.allocator, msg);
        }
    }
}

/// True when a relative `@import` path crosses out of `core` and
/// resolves into `cli/`. Strip every leading `../` segment and
/// inspect whatever the import actually targets.
fn resolvesIntoCli(path: []const u8) bool {
    var rest = path;
    while (std.mem.startsWith(u8, rest, "../")) rest = rest[3..];
    return std.mem.startsWith(u8, rest, "cli/") or
        std.mem.eql(u8, rest, "cli.zig");
}
