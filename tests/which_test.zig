//! malt — which command integration tests
//!
//! Pure resolver and encoder tests live inline in `src/cli/which.zig`
//! (see T-052). This file covers the end-to-end `execute` path that
//! needs a real prefix on disk: directory layout, symlink readlink,
//! and the abort-on-miss surface.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const which = malt.cli_which;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

/// Build a fake malt prefix with `Cellar/<name>/<ver>/bin/<name>` and a
/// `bin/<name>` symlink pointing at it. Returns the prefix path; caller
/// frees + deletes it.
fn makePrefixWithKeg(suffix: []const u8, name: []const u8, version: []const u8) ![:0]u8 {
    const base = try test_io.uniqueTempPath(testing.allocator, "which", suffix);
    defer testing.allocator.free(base);
    const prefix = try std.fmt.allocPrintSentinel(testing.allocator, "{s}", .{base}, 0);
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    const keg_bin = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/{s}/{s}/bin",
        .{ prefix, name, version },
    );
    defer testing.allocator.free(keg_bin);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_bin);

    const real_bin = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ keg_bin, name });
    defer testing.allocator.free(real_bin);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, real_bin, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
    }

    const prefix_bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{prefix});
    defer testing.allocator.free(prefix_bin);
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix_bin);

    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ prefix_bin, name });
    defer testing.allocator.free(link_path);
    try test_io.symLinkAbsolute(std.Options.debug_io, real_bin, link_path, .{});

    return prefix;
}

test "execute resolves a bare binary name through the prefix bin symlink" {
    const prefix = try makePrefixWithKeg("bare", "jq", "1.7.1");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try which.execute(&ctx, testing.allocator, &.{"jq"});
}

test "execute accepts an absolute path under the prefix" {
    const prefix = try makePrefixWithKeg("abs", "wget", "1.25.0");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const abs = try std.fmt.allocPrint(testing.allocator, "{s}/bin/wget", .{prefix});
    defer testing.allocator.free(abs);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try which.execute(&ctx, testing.allocator, &.{abs});
}

test "execute on an unknown name returns Aborted" {
    const prefix = try makePrefixWithKeg("unknown", "wget", "1.25.0");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(error.Aborted, which.execute(&ctx, testing.allocator, &.{"does-not-exist"}));
}

test "execute with no positional arg returns Aborted with usage" {
    try testing.expectError(error.Aborted, which.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{}));
}

test "execute on an absolute path that is not a symlink returns Aborted" {
    const prefix = try makePrefixWithKeg("plain", "tree", "2.2.1");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const plain = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/tree/2.2.1/bin/tree",
        .{prefix},
    );
    defer testing.allocator.free(plain);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(error.Aborted, which.execute(&ctx, testing.allocator, &.{plain}));
}
