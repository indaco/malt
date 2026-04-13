//! malt — cli/tap end-to-end dispatch tests
//! Exercises the `mt tap` subcommand with MALT_PREFIX pointed at a scratch
//! directory, so the dispatch opens a real SQLite database under the prefix.

const std = @import("std");
const testing = std.testing;
const tap_cli = @import("malt").cli_tap;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_cli_tap_{d}_{s}",
        .{ std.time.nanoTimestamp(), suffix },
        0,
    );
    std.fs.deleteTreeAbsolute(path) catch {};
    try std.fs.cwd().makePath(path);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try std.fs.makeDirAbsolute(db_dir);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "execute with no args prints an empty list (no taps registered)" {
    const prefix = try setupPrefix("list_empty");
    defer testing.allocator.free(prefix);
    defer std.fs.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try tap_cli.execute(testing.allocator, &.{});
}

test "execute with user/repo adds a tap idempotently" {
    const prefix = try setupPrefix("add_then_list");
    defer testing.allocator.free(prefix);
    defer std.fs.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try tap_cli.execute(testing.allocator, &.{"user/repo"});
    // A second call is idempotent via INSERT OR IGNORE.
    try tap_cli.execute(testing.allocator, &.{"user/repo"});
    // NOTE: we deliberately do not exercise the bare-`execute` list path when
    // rows are present — in the zig-test-runner listen protocol, writing tap
    // names to stdout deadlocks the parent pipe. The bare list (empty case)
    // is covered by the sibling test above.
}

test "execute with --help short-circuits before touching the database" {
    defer _ = c.unsetenv("MALT_PREFIX");
    _ = c.setenv("MALT_PREFIX", "/tmp/malt_cli_tap_help_no_db", 1);
    // Even though the db dir does not exist, --help must succeed.
    try tap_cli.execute(testing.allocator, &.{"--help"});
}

test "execute with a bare name (no slash) reports an error but does not throw" {
    const prefix = try setupPrefix("bad_name");
    defer testing.allocator.free(prefix);
    defer std.fs.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try tap_cli.execute(testing.allocator, &.{"no_slash_here"});
}
