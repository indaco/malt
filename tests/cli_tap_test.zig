//! malt — cli/tap end-to-end dispatch tests
//! Exercises the `mt tap` subcommand with MALT_PREFIX pointed at a scratch
//! directory, so the dispatch opens a real SQLite database under the prefix.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const tap_cli = @import("malt").cli_tap;
const TapNameError = tap_cli.TapNameError;
const bad = TapNameError.InvalidTapName;
const test_io = @import("test_io");

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
            "user",
            "homebrew-repo",
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
            "user",
            "homebrew-repo",
            "0123456789abcdef0123456789abcdef01234567",
        );
        try malt.tap.add(&db, "x/y", "x", "homebrew-y", null);
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
// --host / --url forge registration
// ---------------------------------------------------------------------------

fn readTapRow(db_path: [:0]const u8, name: []const u8) !struct { host: []u8, owner: []u8, repo: []u8, pinned: bool } {
    var db = try malt.sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT host, github_owner, github_repo, commit_sha FROM taps WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try testing.expect(try stmt.step());
    const host = try testing.allocator.dupe(u8, std.mem.sliceTo(stmt.columnText(0) orelse "", 0));
    const owner = try testing.allocator.dupe(u8, std.mem.sliceTo(stmt.columnText(1) orelse "", 0));
    const repo = try testing.allocator.dupe(u8, std.mem.sliceTo(stmt.columnText(2) orelse "", 0));
    const pinned = stmt.columnText(3) != null;
    return .{ .host = host, .owner = owner, .repo = repo, .pinned = pinned };
}

// Read the nullable `forge` column on its own — the explicit `--forge`
// hint a custom-domain row persists, NULL when classification is by host.
fn readTapForge(db_path: [:0]const u8, name: []const u8) !?[]u8 {
    var db = try malt.sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT forge FROM taps WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try testing.expect(try stmt.step());
    const raw = stmt.columnText(0) orelse return null;
    return try testing.allocator.dupe(u8, std.mem.sliceTo(raw, 0));
}

test "execute --host with --repo registers a non-github tap unpinned, no network" {
    const prefix = try setupPrefix("host_repo_register");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    // Empty environ → if the code routed to GitHub HTTP this would fail;
    // the non-github path must persist without touching the network.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try tap_cli.execute(&ctx, testing.allocator, &.{ "grp/tap", "--host", "gitlab.com", "--repo", "grp/tap" });

    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);
    const row = try readTapRow(db_path, "grp/tap");
    defer testing.allocator.free(row.host);
    defer testing.allocator.free(row.owner);
    defer testing.allocator.free(row.repo);
    try testing.expectEqualStrings("gitlab.com", row.host);
    try testing.expectEqualStrings("grp", row.owner);
    try testing.expectEqualStrings("tap", row.repo);
    try testing.expect(!row.pinned); // unpinned: resolution lands in a later release
}

test "execute --host with --forge persists the explicit provider for a custom domain" {
    // A corporate GitLab on a custom domain (code.acme.com) can't be
    // classified from its host, so --forge is the only signal; it must
    // persist so resolution targets GitLab, not the github default.
    const prefix = try setupPrefix("forge_hint_register");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try tap_cli.execute(&ctx, testing.allocator, &.{ "acme/tap", "--host", "code.acme.com", "--forge", "gitlab", "--repo", "acme/tap" });

    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);
    const row = try readTapRow(db_path, "acme/tap");
    defer testing.allocator.free(row.host);
    defer testing.allocator.free(row.owner);
    defer testing.allocator.free(row.repo);
    try testing.expectEqualStrings("code.acme.com", row.host);

    const stored_forge = try readTapForge(db_path, "acme/tap");
    defer if (stored_forge) |f| testing.allocator.free(f);
    try testing.expectEqualStrings("gitlab", stored_forge orelse "");
}

test "execute --forge rejects an unknown provider" {
    const prefix = try setupPrefix("forge_unknown");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(error.Aborted, tap_cli.execute(&ctx, testing.allocator, &.{ "acme/tap", "--host", "code.acme.com", "--forge", "bogus", "--repo", "acme/tap" }));
}

test "execute --forge without a host is rejected" {
    const prefix = try setupPrefix("forge_no_host");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(error.Aborted, tap_cli.execute(&ctx, testing.allocator, &.{ "acme/tap", "--forge", "gitlab", "--repo", "acme/tap" }));
}

test "execute --forge combined with --refresh is rejected" {
    const prefix = try setupPrefix("forge_refresh");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(error.Aborted, tap_cli.execute(&ctx, testing.allocator, &.{ "--refresh", "acme/tap", "--forge", "gitlab" }));
}

test "execute --forge=<value> inline form is parsed (rejects an unknown provider)" {
    const prefix = try setupPrefix("forge_inline");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(error.Aborted, tap_cli.execute(&ctx, testing.allocator, &.{ "acme/tap", "--host", "code.acme.com", "--forge=bogus", "--repo", "acme/tap" }));
}

test "execute --url derives and persists (host, owner, repo) unpinned" {
    const prefix = try setupPrefix("url_register");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try tap_cli.execute(&ctx, testing.allocator, &.{ "mygrp/mytap", "--url", "https://codeberg.org/o/r" });

    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);
    const row = try readTapRow(db_path, "mygrp/mytap");
    defer testing.allocator.free(row.host);
    defer testing.allocator.free(row.owner);
    defer testing.allocator.free(row.repo);
    try testing.expectEqualStrings("codeberg.org", row.host);
    try testing.expectEqualStrings("o", row.owner);
    try testing.expectEqualStrings("r", row.repo);
    try testing.expect(!row.pinned);
}

test "execute --host without an explicit repo fails with a hint, not a homebrew- guess" {
    const prefix = try setupPrefix("host_no_repo");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{ "grp/tap", "--host", "gitlab.com" }),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, "needs an explicit repo") != null);
}

test "execute rejects a --host that carries a scheme or path" {
    const prefix = try setupPrefix("host_bad");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{ "grp/tap", "--host", "https://gitlab.com", "--repo", "grp/tap" }),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, "Invalid --host") != null);
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

test "execute rejects --repo without a positional slug" {
    // `mt tap --repo X/Y` with no slug is meaningless — refuse early
    // rather than silently dispatching to the listing branch.
    const prefix = try setupPrefix("repo_no_positional");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{ "--repo", "aeroxy/ast-outline" }),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, "Usage:") != null);
}

test "execute rejects --repo combined with --refresh" {
    const prefix = try setupPrefix("repo_with_refresh");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{
            "user/repo", "--repo", "user/repo", "--refresh",
        }),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, "--repo cannot be combined") != null);
}

test "execute rejects --force without --repo (no-op flag, surface the mistake)" {
    const prefix = try setupPrefix("force_without_repo");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{ "user/repo", "--force" }),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, "--force is only valid") != null);
}

test "execute reports a clean error on a malformed --repo value" {
    const prefix = try setupPrefix("repo_malformed");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{ "user/repo", "--repo", "no-slash" }),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, "Invalid --repo") != null);
}

test "execute rejects --repo over an existing row that pins a different pair" {
    // Rebind policy: refuse without --force. The refusal fires before
    // any HTTP work so the assertion is deterministic against a row
    // already bound to a different (owner, repo).
    const prefix = try setupPrefix("repo_rebind_refuse");
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
            "aeroxy/ast-outline",
            "aeroxy",
            "homebrew-ast-outline",
            null,
        );
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{
            "aeroxy/ast-outline", "--repo", "aeroxy/ast-outline",
        }),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, "--force") != null);
}

test "execute --repo --force rebinds the row and clears the stale pin before any HTTP work" {
    // Force-rebind invalidates the pin upfront so a network failure
    // can't leave the row pointing at the new repo with the old SHA.
    // We drive that invariant with a deliberately-404ing target so the
    // post-rebind HEAD resolve fails — the rebind side effects must
    // already be visible in the DB by then.
    const prefix = try setupPrefix("repo_force_rebind");
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

    const stale_sha = "0123456789abcdef0123456789abcdef01234567";
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        try malt.tap.add(&db, "aeroxy/tap", "aeroxy", "homebrew-tap", stale_sha);
        try malt.tap.updateHead(&db, "aeroxy/tap", stale_sha, "W/\"stale-etag\"");
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{
        .io = threaded.io(),
        .environ = malt.app_ctx.processEnviron(),
    };

    // `aeroxy/this-repo-does-not-exist-...` is a deterministic 404
    // against api.github.com — the rebind runs before the resolve, so
    // the row mutation is observable even though the command aborts.
    try testing.expectError(
        error.Aborted,
        tap_cli.execute(&ctx, testing.allocator, &.{
            "aeroxy/tap", "--repo", "aeroxy/missing-prefixless-repo", "--force",
        }),
    );

    // The "needs refresh" warning fires only when rebind landed before
    // the resolve failure — pinning the message guards the ordering.
    try testing.expect(std.mem.indexOf(u8, captured.items, "Rebind applied with no pin") != null);

    var db = try malt.sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare(
        "SELECT github_owner, github_repo, commit_sha, head_etag FROM taps WHERE name = ?1;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, "aeroxy/tap");
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings(
        "aeroxy",
        std.mem.sliceTo(stmt.columnText(0) orelse "", 0),
    );
    try testing.expectEqualStrings(
        "missing-prefixless-repo",
        std.mem.sliceTo(stmt.columnText(1) orelse "", 0),
    );
    try testing.expect(stmt.columnText(2) == null);
    try testing.expect(stmt.columnText(3) == null);
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
            "user",
            "homebrew-repo",
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
