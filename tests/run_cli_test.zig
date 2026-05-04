//! malt — `mt run` command early-branch tests.
//!
//! `run.execute` ultimately `exec`s the discovered binary, so the
//! happy-path tail can't return into the test runner. This file pins
//! every reachable branch up to that point — argument parsing, path
//! formatters, the help short-circuit, and the ephemeral-fetch
//! Aborted path when the formula API reports 404.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const run = malt.cli_run;
const output = malt.output;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const ts = test_io.nanoTimestamp(std.Options.debug_io);
        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "/tmp/malt_run_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const cache_api = try std.fmt.allocPrint(allocator, "{s}/cache/api", .{path});
        defer allocator.free(cache_api);
        try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }
};

fn quiet() void {
    output.setQuiet(true);
}
fn unquiet() void {
    output.setQuiet(false);
}

// --- parseArgs -----------------------------------------------------------

test "parseArgs returns null when no positional package is present" {
    try testing.expect(run.parseArgs(&.{}) == null);
    try testing.expect(run.parseArgs(&.{"--keep"}) == null);
}

test "parseArgs picks up the bare package name" {
    const p = run.parseArgs(&.{"jq"}) orelse return error.ExpectedParse;
    try testing.expectEqualStrings("jq", p.pkg_name);
    try testing.expect(!p.keep);
    try testing.expectEqual(@as(usize, 0), p.cmd_args.len);
}

test "parseArgs handles --keep before the package" {
    const p = run.parseArgs(&.{ "--keep", "jq" }) orelse return error.ExpectedParse;
    try testing.expectEqualStrings("jq", p.pkg_name);
    try testing.expect(p.keep);
}

test "parseArgs handles --keep after the package" {
    const p = run.parseArgs(&.{ "jq", "--keep" }) orelse return error.ExpectedParse;
    try testing.expectEqualStrings("jq", p.pkg_name);
    try testing.expect(p.keep);
}

test "parseArgs forwards everything after `--` as cmd_args" {
    const p = run.parseArgs(&.{ "jq", "--", "-c", ".name" }) orelse return error.ExpectedParse;
    try testing.expectEqualStrings("jq", p.pkg_name);
    try testing.expectEqual(@as(usize, 2), p.cmd_args.len);
    try testing.expectEqualStrings("-c", p.cmd_args[0]);
    try testing.expectEqualStrings(".name", p.cmd_args[1]);
}

test "parseArgs returns null if `--` appears before any package name" {
    try testing.expect(run.parseArgs(&.{ "--", "-v" }) == null);
}

// --- path formatters -----------------------------------------------------

test "buildKeepCachePath joins {cache}/run/<sha>" {
    var buf: [256]u8 = undefined;
    const path = try run.buildKeepCachePath(&buf, "/tmp/cache", "abc123");
    try testing.expectEqualStrings("/tmp/cache/run/abc123", path);
}

test "buildKeepLockPath appends .lock siblings to the cache slot" {
    var buf: [256]u8 = undefined;
    const path = try run.buildKeepLockPath(&buf, "/tmp/cache", "abc123");
    try testing.expectEqualStrings("/tmp/cache/run/abc123.lock", path);
}

test "buildKeepCachePath surfaces PathTooLong on tiny buffers" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.PathTooLong, run.buildKeepCachePath(&buf, "/tmp/cache", "abc123"));
}

// --- execute early-return branches ---------------------------------------

test "execute --help short-circuits without parsing args" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try run.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute with no positional package returns Aborted" {
    var s = try Scratch.init(testing.allocator, "noargs");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        run.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

test "execute on a cached-404 formula returns Aborted before exec" {
    // Plant a fresh `formula_<pkg>.404` marker so api.fetchFormula
    // short-circuits on `readNotFoundCache` and run takes the
    // "Formula not found" Aborted branch instead of hitting the network.
    var s = try Scratch.init(testing.allocator, "cached_404");
    defer s.deinit(testing.allocator);

    const marker_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/cache/api/formula_ghost-pkg.404",
        .{s.path},
    );
    defer testing.allocator.free(marker_path);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, marker_path, .{ .truncate = true });
    f.close(std.Options.debug_io);

    quiet();
    defer unquiet();

    try testing.expectError(
        error.Aborted,
        run.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"ghost-pkg"}),
    );
}
