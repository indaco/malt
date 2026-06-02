//! Pin test: `src/core/forge.zig` is a pure leaf — it imports neither
//! `cli/*` nor `ui/*`. The forge seam exists so a new host is one enum
//! arm; letting it reach into the CLI or render layer would re-couple
//! the very concerns it was extracted to isolate. Mirrors
//! `tests/no_io_mod_in_src_test.zig`.

const std = @import("std");
const testing = std.testing;
const test_io = @import("test_io");

const forge_path = "src/core/forge.zig";
const import_prefix = "@import(\"";

test "core/forge.zig imports neither cli/* nor ui/*" {
    const io = std.Options.debug_io;

    var dir = try test_io.cwd().openDir(io, "src/core", .{});
    defer dir.close(io);

    const file = try dir.openFile(io, "forge.zig", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const content = try testing.allocator.alloc(u8, @intCast(stat.size));
    defer testing.allocator.free(content);
    _ = try file.readPositionalAll(io, content, 0);

    var failures: std.ArrayList([]const u8) = .empty;
    defer {
        for (failures.items) |s| testing.allocator.free(s);
        failures.deinit(testing.allocator);
    }

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, import_prefix)) |start| {
        const path_start = start + import_prefix.len;
        const end = std.mem.indexOfScalarPos(u8, content, path_start, '"') orelse break;
        const import_path = content[path_start..end];
        cursor = end + 1;

        if (crossesInto(import_path, "cli") or crossesInto(import_path, "ui")) {
            const msg = try std.fmt.allocPrint(
                testing.allocator,
                "{s} imports {s}",
                .{ forge_path, import_path },
            );
            try failures.append(testing.allocator, msg);
        }
    }

    if (failures.items.len != 0) {
        for (failures.items) |f| std.debug.print("{s}\n", .{f});
        return error.ForgeIsNotALeaf;
    }
}

/// True when a relative `@import` path resolves into `<layer>/` after
/// stripping leading `../` segments.
fn crossesInto(path: []const u8, comptime layer: []const u8) bool {
    var rest = path;
    while (std.mem.startsWith(u8, rest, "../")) rest = rest[3..];
    return std.mem.startsWith(u8, rest, layer ++ "/") or
        std.mem.eql(u8, rest, layer ++ ".zig");
}
