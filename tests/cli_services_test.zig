//! malt — cli/services dispatch tests
//! Drives the `mt services` subcommand router with MALT_PREFIX pointed at
//! a scratch directory. Covers describeError, printHelp, the unknown-subcommand
//! path, list/ls, status, and logs (missing-file fallback).

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const services_cli = malt.cli_services;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_cli_services_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
        0,
    );
    malt.fs_compat.deleteTreeAbsolute(path) catch {};
    try malt.fs_compat.cwd().makePath(path);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.makeDirAbsolute(db_dir);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "describeError returns a distinct message for every ServicesError tag" {
    const a = services_cli.describeError(error.InvalidArgs);
    const b = services_cli.describeError(error.DatabaseError);
    const d = services_cli.describeError(error.SupervisorError);
    try testing.expect(a.len > 0 and b.len > 0 and d.len > 0);
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(!std.mem.eql(u8, b, d));
}

test "execute with no args prints help" {
    defer _ = c.unsetenv("MALT_PREFIX");
    _ = c.setenv("MALT_PREFIX", "/tmp/malt_cli_services_help_noargs", 1);
    try services_cli.execute(testing.allocator, &.{});
}

test "execute with -h / --help prints help" {
    defer _ = c.unsetenv("MALT_PREFIX");
    _ = c.setenv("MALT_PREFIX", "/tmp/malt_cli_services_help_flag", 1);
    try services_cli.execute(testing.allocator, &.{"-h"});
    try services_cli.execute(testing.allocator, &.{"--help"});
}

test "execute list on an empty prefix reports no services" {
    const prefix = try setupPrefix("list_empty");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try services_cli.execute(testing.allocator, &.{"list"});
    try services_cli.execute(testing.allocator, &.{"ls"});
    // status with no name falls back to the list path.
    try services_cli.execute(testing.allocator, &.{"status"});
}

test "execute with an unknown subcommand returns InvalidArgs" {
    const prefix = try setupPrefix("unknown");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try testing.expectError(
        error.InvalidArgs,
        services_cli.execute(testing.allocator, &.{"flarble"}),
    );
}

test "execute status with a non-existent service returns SupervisorError" {
    const prefix = try setupPrefix("status_missing");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try testing.expectError(
        error.SupervisorError,
        services_cli.execute(testing.allocator, &.{ "status", "nope" }),
    );
}

test "execute start/stop/restart with wrong arity returns InvalidArgs" {
    const prefix = try setupPrefix("lifecycle_argv");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    for ([_][]const u8{ "start", "stop", "restart" }) |op| {
        try testing.expectError(
            error.InvalidArgs,
            services_cli.execute(testing.allocator, &.{op}),
        );
    }
}

test "execute logs with no args returns InvalidArgs" {
    const prefix = try setupPrefix("logs_noargs");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try testing.expectError(
        error.InvalidArgs,
        services_cli.execute(testing.allocator, &.{"logs"}),
    );
}

// NOTE: cmdLogs writes to stdout, which deadlocks the zig-test-runner listen
// protocol. The happy path (finding and tailing the log file) is covered by
// the supervisor_pure_test suite via a direct tailLog call; here we limit the
// CLI-level coverage to the error branches that never reach stdout.
