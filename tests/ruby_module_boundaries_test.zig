//! Pin test: the ruby_subprocess split keeps detect / source / spawn
//! import-isolated. Detection drags neither the DSL parser nor the HTTP
//! client; source extraction drags no sandbox; the spawn driver reaches
//! the DSL and net only through `source.zig`. This is what stops DSL-only
//! and net-only tests from cross-linking through the subprocess driver.

const std = @import("std");
const testing = std.testing;

const test_io = @import("test_io");

const import_prefix = "@import(\"";

const Boundary = struct {
    file: []const u8,
    forbidden: []const []const u8,
};

const boundaries = [_]Boundary{
    // Detection is pure path probing — no DSL, no net.
    .{ .file = "src/core/ruby/detect.zig", .forbidden = &.{ "dsl/", "net/" } },
    // Source extraction owns DSL + net; it must not reach the sandbox.
    .{ .file = "src/core/ruby/source.zig", .forbidden = &.{"sandbox/macos.zig"} },
    // The spawn driver reaches DSL/net only via source.zig, never directly.
    .{ .file = "src/core/ruby_subprocess.zig", .forbidden = &.{
        "dsl/lexer.zig",
        "dsl/parser.zig",
        "net/api.zig",
        "net/client.zig",
    } },
};

test "ruby split modules import only what each role needs" {
    const io = std.Options.debug_io;

    var failures: std.ArrayList([]const u8) = .empty;
    defer {
        for (failures.items) |s| testing.allocator.free(s);
        failures.deinit(testing.allocator);
    }

    for (boundaries) |b| {
        const content = try readRelative(io, b.file);
        defer testing.allocator.free(content);
        try scanImports(b, content, &failures);
    }

    if (failures.items.len != 0) {
        for (failures.items) |f| std.debug.print("{s}\n", .{f});
        return error.RubyModuleBoundaryViolated;
    }
}

fn readRelative(io: std.Io, rel_path: []const u8) ![]u8 {
    const file = try test_io.cwd().openFile(io, rel_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try testing.allocator.alloc(u8, @intCast(stat.size));
    errdefer testing.allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

fn scanImports(b: Boundary, content: []const u8, failures: *std.ArrayList([]const u8)) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, import_prefix)) |start| {
        const path_start = start + import_prefix.len;
        const end = std.mem.indexOfScalarPos(u8, content, path_start, '"') orelse break;
        const import_path = content[path_start..end];
        cursor = end + 1;

        for (b.forbidden) |needle| {
            if (std.mem.indexOf(u8, import_path, needle) != null) {
                const msg = try std.fmt.allocPrint(
                    testing.allocator,
                    "{s} imports {s} (forbidden: {s})",
                    .{ b.file, import_path, needle },
                );
                try failures.append(testing.allocator, msg);
            }
        }
    }
}
