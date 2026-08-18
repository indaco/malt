//! malt — aggregate test-target drift guard
//!
//! `zig build test-one` runs the whole suite in two binaries instead of ~160.
//! It only delivers that if the aggregate root actually pulls every test file
//! into its own module: Zig collects `test` blocks from the root module's
//! files, so a file wired in as a named *module* import compiles but never
//! runs. The aggregate used to import its entries that way, which meant the
//! fast loop reported success without executing a single `tests/` block.
//!
//! Nothing in a passing run can reveal that - the failure mode is silence -
//! so the guard derives the truth from the directory: every `tests/*_test.zig`
//! on disk must be imported by `tests/all.zig` (a file path, so its tests are
//! collected) and listed in `build.zig` (so the per-file target keeps it too).
//! A file that reaches neither is a test nobody runs.

const std = @import("std");
const testing = std.testing;
const test_io = @import("test_io");

const io = std.Options.debug_io;

fn readRepoFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try test_io.cwd().openFile(io, path, .{});
    defer f.close(io);
    return test_io.readFileToEndAlloc(f, allocator, 4 * 1024 * 1024);
}

/// Every `*_test.zig` under `tests/`, sorted, caller owns each name and the slice.
fn testFileNames(allocator: std.mem.Allocator) ![][]const u8 {
    var dir = try test_io.cwd().openDir(io, "tests", .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, "_test.zig")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(allocator);
}

test "every tests/*_test.zig is imported by the aggregate root" {
    const a = testing.allocator;
    const names = try testFileNames(a);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    try testing.expect(names.len > 100); // the suite is large; a tiny count means the scan broke

    const all_src = try readRepoFile(a, "tests/all.zig");
    defer a.free(all_src);

    var missing: usize = 0;
    for (names) |name| {
        // A *file* import - `@import("x_test.zig")` - is what puts the file in
        // the root module. A bare module name would compile and never run.
        const needle = try std.fmt.allocPrint(a, "@import(\"{s}\")", .{name});
        defer a.free(needle);
        if (std.mem.indexOf(u8, all_src, needle) == null) {
            missing += 1;
            std.debug.print("tests/all.zig does not import {s}\n", .{name});
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "every tests/*_test.zig is listed in build.zig" {
    const a = testing.allocator;
    const names = try testFileNames(a);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }

    const build_src = try readRepoFile(a, "build.zig");
    defer a.free(build_src);

    var missing: usize = 0;
    for (names) |name| {
        const needle = try std.fmt.allocPrint(a, "\"tests/{s}\"", .{name});
        defer a.free(needle);
        if (std.mem.indexOf(u8, build_src, needle) == null) {
            missing += 1;
            std.debug.print("build.zig does not list tests/{s}\n", .{name});
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "the aggregate root imports nothing that is not on disk" {
    const a = testing.allocator;
    const all_src = try readRepoFile(a, "tests/all.zig");
    defer a.free(all_src);

    var stale: usize = 0;
    var it = std.mem.splitSequence(u8, all_src, "@import(\"");
    _ = it.next(); // text before the first import
    while (it.next()) |rest| {
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const name = rest[0..end];
        const path = try std.fmt.allocPrint(a, "tests/{s}", .{name});
        defer a.free(path);
        test_io.cwd().access(io, path, .{}) catch {
            stale += 1;
            std.debug.print("tests/all.zig imports missing file {s}\n", .{name});
        };
    }
    try testing.expectEqual(@as(usize, 0), stale);
}
