//! malt — cli/tap end-to-end dispatch tests
//! Exercises the `mt tap` subcommand with MALT_PREFIX pointed at a scratch
//! directory, so the dispatch opens a real SQLite database under the prefix.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
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
        .{ test_io.nanoTimestamp(
            std.Options.debug_io,
        ), suffix },
        0,
    );
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, db_dir);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "execute with no args prints an empty list (no taps registered)" {
    const prefix = try setupPrefix("list_empty");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try tap_cli.execute(&ctx, testing.allocator, &.{});
}

test "execute with --json on a prefix with no db/ directory still emits `[]`" {
    // Fresh MALT_PREFIX where the `db/` dir doesn't exist yet: `sqlite.open`
    // fails. CI consumers piping through `jq` need a parseable empty array,
    // not silently-empty stdout.
    const path = "/tmp/malt_cli_tap_fresh_no_db";
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    _ = c.setenv("MALT_PREFIX", path, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try tap_cli.execute(&ctx, testing.allocator, &.{});
    try testing.expectEqualStrings("[]\n", stdout_buf.items);
}

test "execute with --json on an empty DB emits `[]`" {
    const prefix = try setupPrefix("list_empty_json");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try tap_cli.execute(&ctx, testing.allocator, &.{});
    try testing.expectEqualStrings("[]\n", stdout_buf.items);
}

test "execute with --json output is a parseable JSON array" {
    const prefix = try setupPrefix("list_json_parse");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/db/malt.db",
        .{prefix},
        0,
    );
    defer testing.allocator.free(db_path);
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        try malt.tap.add(
            &db,
            "user/repo",
            "https://github.com/user/homebrew-repo",
            "0123456789abcdef0123456789abcdef01234567",
        );
    }

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try tap_cli.execute(&ctx, testing.allocator, &.{});

    const trimmed = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, trimmed, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try testing.expectEqualStrings("user/repo", parsed.value.array.items[0].object.get("name").?.string);
}

test "execute with --json on a populated DB emits one object per tap" {
    const prefix = try setupPrefix("list_populated_json");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/db/malt.db",
        .{prefix},
        0,
    );
    defer testing.allocator.free(db_path);
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        try malt.tap.add(
            &db,
            "user/repo",
            "https://github.com/user/homebrew-repo",
            "0123456789abcdef0123456789abcdef01234567",
        );
        try malt.tap.add(&db, "x/y", "https://github.com/x/homebrew-y", null);
    }

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try tap_cli.execute(&ctx, testing.allocator, &.{});

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"user/repo\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"url\":\"https://github.com/user/homebrew-repo\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"commit_sha\":\"0123456789abcdef0123456789abcdef01234567\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"x/y\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"commit_sha\":null") != null);
    try testing.expect(std.mem.startsWith(u8, stdout_buf.items, "["));
    try testing.expect(std.mem.endsWith(u8, stdout_buf.items, "]\n"));
}

test "execute with unresolvable user/repo aborts (no network pin = no add)" {
    const prefix = try setupPrefix("unresolvable");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // `user/repo` isn't a real GitHub repo; HEAD resolution fails and
    // we refuse to register an unpinned tap. Idempotency + list-with-
    // rows paths are covered by tests/tap_test.zig directly against
    // `tap_mod`, which doesn't need network.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{"user/repo"}),
    );
}

test "execute with --help short-circuits before touching the database" {
    defer _ = c.unsetenv("MALT_PREFIX");
    _ = c.setenv("MALT_PREFIX", "/tmp/malt_cli_tap_help_no_db", 1);
    // Even though the db dir does not exist, --help must succeed.
    try tap_cli.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
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
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // Each of these should be rejected by the validator and surface as a
    // non-zero CLI exit — the command-level contract is `error.Aborted`
    // (see main.zig dispatch). Run them back-to-back to also verify no
    // partial state accumulates between calls.
    const bad_inputs = [_][]const u8{
        "no-slash-here", "a/b/c", "/repo", "user/", "../evil", "user/bad char",
    };
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    for (bad_inputs) |name| {
        try testing.expectError(
            error.Aborted,
            tap_cli.execute(&ctx, testing.allocator, &.{name}),
        );
    }
}

test "execute with a bare name (no slash) surfaces error.Aborted" {
    const prefix = try setupPrefix("bad_name");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{"no_slash_here"}),
    );
}

// ---------------------------------------------------------------------------
// --pin <user/repo> <sha>
// ---------------------------------------------------------------------------

test "execute --pin without two operands aborts" {
    const prefix = try setupPrefix("pin_missing_operand");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{"--pin"}),
    );
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{ "--pin", "user/repo" }),
    );
}

test "execute --pin with malformed SHA aborts before any network call" {
    const prefix = try setupPrefix("pin_bad_sha");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    // Empty environ guarantees no live network configuration is in play;
    // if the implementation routes to HTTP this will hang or error noisily.
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{ "--pin", "user/repo", "deadbeef" }),
    );
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{ "--pin", "user/repo", "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG" }),
    );
}

test "execute --pin with malformed tap name aborts" {
    const prefix = try setupPrefix("pin_bad_tap");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{
            "--pin", "no_slash_here", "0123456789abcdef0123456789abcdef01234567",
        }),
    );
}

test "execute --pin under `mt untap` is rejected" {
    const prefix = try setupPrefix("pin_under_untap");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        tap_cli.executeUntap(&ctx, testing.allocator, &.{
            "--pin", "user/repo", "0123456789abcdef0123456789abcdef01234567",
        }),
    );
}

test "execute --pin with unresolvable repo surfaces error.Aborted" {
    const prefix = try setupPrefix("pin_unresolvable");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // `user/repo` is not a real homebrew tap — the commits/<sha> endpoint
    // 404s and the pin must be refused, mirroring the `mt tap` add path.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{
        .io = threaded.io(),
        .environ = malt.app_ctx.processEnviron(),
    };
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{
            "--pin", "user/repo", "0123456789abcdef0123456789abcdef01234567",
        }),
    );
}

// ---------------------------------------------------------------------------
// --refresh --all
// ---------------------------------------------------------------------------

test "execute --refresh --all on an empty DB is a clean no-op" {
    const prefix = try setupPrefix("refresh_all_empty");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    // No taps registered → no diff, no apply, exit 0.
    try tap_cli.execute(&ctx, testing.allocator, &.{ "--refresh", "--all" });
    try tap_cli.execute(&ctx, testing.allocator, &.{ "--refresh", "--all", "--yes" });
}

test "execute --refresh --all under `mt untap` is rejected" {
    const prefix = try setupPrefix("refresh_all_under_untap");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        tap_cli.executeUntap(&ctx, testing.allocator, &.{ "--refresh", "--all" }),
    );
}

test "execute --refresh --all with only failed rows does not gate the apply" {
    // Pre-seed a row whose remote 404s. `--all` walks it, surfaces the
    // failure, but the no-moved-rows path still exits cleanly without
    // requiring `--yes`. Confirms the `anyMoved` gate is failure-tolerant.
    const prefix = try setupPrefix("refresh_all_failed_only");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/db/malt.db",
        .{prefix},
        0,
    );
    defer testing.allocator.free(db_path);
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        try malt.tap.add(
            &db,
            "user/repo",
            "https://github.com/user/homebrew-repo",
            "0123456789abcdef0123456789abcdef01234567",
        );
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{
        .io = threaded.io(),
        .environ = malt.app_ctx.processEnviron(),
    };
    // The remote 404s → row is `failed` → not gated → exit clean.
    try tap_cli.execute(&ctx, testing.allocator, &.{ "--refresh", "--all" });
}
