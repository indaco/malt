//! malt — cli/tap end-to-end dispatch tests
//! Exercises the `mt tap` subcommand with MALT_PREFIX pointed at a scratch
//! directory, so the dispatch opens a real SQLite database under the prefix.

const std = @import("std");
const malt = @import("malt");
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

test "execute with no args prints an empty list (no taps registered)" {
    const prefix = try setupPrefix("list_empty");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try tap_cli.execute(testing.allocator, &.{});
}

test "execute with user/repo adds a tap idempotently" {
    const prefix = try setupPrefix("add_then_list");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
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

// ---------------------------------------------------------------------------
// validateTapName
// ---------------------------------------------------------------------------

const TapNameError = tap_cli.TapNameError;
const bad = TapNameError.InvalidTapName;

test "validateTapName: accepts canonical user/repo" {
    try tap_cli.validateTapName("homebrew/core");
    try tap_cli.validateTapName("homebrew/cask");
    try tap_cli.validateTapName("hashicorp/tap");
    try tap_cli.validateTapName("goreleaser/tap");
    try tap_cli.validateTapName("indaco/tap");
    try tap_cli.validateTapName("a/b");
    try tap_cli.validateTapName("user_name/repo-name");
    try tap_cli.validateTapName("User123/Repo.v2");
}

test "validateTapName: rejects missing slash" {
    try testing.expectError(bad, tap_cli.validateTapName("noslash"));
    try testing.expectError(bad, tap_cli.validateTapName(""));
}

test "validateTapName: rejects extra slashes (three-part user/tap/formula form)" {
    // `mt tap` takes only the tap name; three-part refs like
    // `goreleaser/tap/goreleaser` or `indaco/tap/sley` are for
    // `mt install`, not `mt tap`, and must be rejected here.
    try testing.expectError(bad, tap_cli.validateTapName("a/b/c"));
    try testing.expectError(bad, tap_cli.validateTapName("goreleaser/tap/goreleaser"));
    try testing.expectError(bad, tap_cli.validateTapName("indaco/tap/sley"));
}

test "validateTapName: rejects empty components" {
    try testing.expectError(bad, tap_cli.validateTapName("/repo"));
    try testing.expectError(bad, tap_cli.validateTapName("user/"));
    try testing.expectError(bad, tap_cli.validateTapName("/"));
}

test "validateTapName: rejects path traversal via leading dot" {
    try testing.expectError(bad, tap_cli.validateTapName("user/.."));
    try testing.expectError(bad, tap_cli.validateTapName("../repo"));
    try testing.expectError(bad, tap_cli.validateTapName(".hidden/repo"));
    try testing.expectError(bad, tap_cli.validateTapName("user/.hidden"));
}

test "validateTapName: rejects invalid characters" {
    try testing.expectError(bad, tap_cli.validateTapName("user/repo space"));
    try testing.expectError(bad, tap_cli.validateTapName("user/repo;rm"));
    try testing.expectError(bad, tap_cli.validateTapName("user/repo?q=1"));
    try testing.expectError(bad, tap_cli.validateTapName("user@host/repo"));
}

test "validateTapName: rejects over-long components" {
    const long_user = "a" ** 65 ++ "/repo";
    try testing.expectError(bad, tap_cli.validateTapName(long_user));
    const long_repo = "user/" ++ "b" ** 65;
    try testing.expectError(bad, tap_cli.validateTapName(long_repo));
}

test "execute: malformed tap input is rejected with error.Aborted" {
    const prefix = try setupPrefix("reject_malformed");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // Each of these should be rejected by the validator and surface as a
    // non-zero CLI exit — the command-level contract is `error.Aborted`
    // (see main.zig dispatch). Run them back-to-back to also verify no
    // partial state accumulates between calls.
    const bad_inputs = [_][]const u8{
        "no-slash-here", "a/b/c", "/repo", "user/", "../evil", "user/bad char",
    };
    for (bad_inputs) |name| {
        try testing.expectError(
            error.Aborted,
            tap_cli.execute(testing.allocator, &.{name}),
        );
    }
}

test "execute with a bare name (no slash) surfaces error.Aborted" {
    const prefix = try setupPrefix("bad_name");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try testing.expectError(
        error.Aborted,
        tap_cli.execute(testing.allocator, &.{"no_slash_here"}),
    );
}
