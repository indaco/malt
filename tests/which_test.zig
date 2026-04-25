//! malt — which command integration tests
//!
//! Pure resolver and encoder tests live inline in `src/cli/which.zig`
//! (see T-052). This file covers the end-to-end `execute` path that
//! needs a real prefix on disk: directory layout, symlink readlink,
//! and the abort-on-miss surface.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const which = malt.cli_which;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

/// Build a fake malt prefix with `Cellar/<name>/<ver>/bin/<name>` and a
/// `bin/<name>` symlink pointing at it. Returns the prefix path; caller
/// frees + deletes it.
fn makePrefixWithKeg(suffix: []const u8, name: []const u8, version: []const u8) ![:0]u8 {
    const prefix = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_which_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
        0,
    );
    malt.fs_compat.deleteTreeAbsolute(prefix) catch {};

    const keg_bin = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/{s}/{s}/bin",
        .{ prefix, name, version },
    );
    defer testing.allocator.free(keg_bin);
    try malt.fs_compat.cwd().makePath(keg_bin);

    const real_bin = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ keg_bin, name });
    defer testing.allocator.free(real_bin);
    {
        const f = try malt.fs_compat.createFileAbsolute(real_bin, .{ .truncate = true });
        defer f.close();
    }

    const prefix_bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{prefix});
    defer testing.allocator.free(prefix_bin);
    try malt.fs_compat.cwd().makePath(prefix_bin);

    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ prefix_bin, name });
    defer testing.allocator.free(link_path);
    try malt.fs_compat.symLinkAbsolute(real_bin, link_path, .{});

    return prefix;
}

test "execute resolves a bare binary name through the prefix bin symlink" {
    const prefix = try makePrefixWithKeg("bare", "jq", "1.7.1");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    try which.execute(testing.allocator, &.{"jq"});
}

test "execute accepts an absolute path under the prefix" {
    const prefix = try makePrefixWithKeg("abs", "wget", "1.25.0");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const abs = try std.fmt.allocPrint(testing.allocator, "{s}/bin/wget", .{prefix});
    defer testing.allocator.free(abs);

    try which.execute(testing.allocator, &.{abs});
}

test "execute on an unknown name returns Aborted" {
    const prefix = try makePrefixWithKeg("unknown", "wget", "1.25.0");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    try testing.expectError(error.Aborted, which.execute(testing.allocator, &.{"does-not-exist"}));
}

test "execute with no positional arg returns Aborted with usage" {
    try testing.expectError(error.Aborted, which.execute(testing.allocator, &.{}));
}

test "execute on an absolute path that is not a symlink returns Aborted" {
    const prefix = try makePrefixWithKeg("plain", "tree", "2.2.1");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const plain = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/tree/2.2.1/bin/tree",
        .{prefix},
    );
    defer testing.allocator.free(plain);
    try testing.expectError(error.Aborted, which.execute(testing.allocator, &.{plain}));
}
