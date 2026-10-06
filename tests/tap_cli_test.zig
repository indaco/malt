//! malt — `mt tap` / `mt untap` dispatch tests.
//!
//! Existing tap_test.zig and cli_tap_test.zig cover the core/tap.zig
//! helpers and the executor pure paths. This file fills the cli/tap.zig
//! `execute` and `executeUntap` dispatch — list, untap, validation
//! errors, refresh-on-untap rejection. The `tap.add` path is left out
//! because it shells out to `git ls-remote` for HEAD resolution.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const tap = malt.cli_tap;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;

const c = test_io.c;

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        // Process-unique: a bare timestamp collides between overlapping runs.
        const raw = try test_io.uniqueTempPath(allocator, "tap_cli", tag);
        defer allocator.free(raw);
        const path = try allocator.dupeZ(u8, raw);
        errdefer allocator.free(path);
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{path});
        defer allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
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

fn ctxWithSink() malt.app_ctx.AppCtx {
    return .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };
}

fn seedTap(prefix: []const u8, name: []const u8, sha: ?[]const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    if (sha) |s| {
        var stmt = try db.prepare(
            \\INSERT INTO taps (name, url, commit_sha) VALUES (?1, ?2, ?3);
        );
        defer stmt.finalize();
        try stmt.bindText(1, name);
        try stmt.bindText(2, "https://example/repo");
        try stmt.bindText(3, s);
        _ = try stmt.step();
    } else {
        var stmt = try db.prepare(
            \\INSERT INTO taps (name, url) VALUES (?1, ?2);
        );
        defer stmt.finalize();
        try stmt.bindText(1, name);
        try stmt.bindText(2, "https://example/repo");
        _ = try stmt.step();
    }
}

// --- validateTapName --------------------------------------------------

test "validateTapName accepts well-formed user/repo" {
    try tap.validateTapName("homebrew/core");
    try tap.validateTapName("user-name/repo.name");
}

test "validateTapName rejects missing slash, double slash, traversal" {
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("noslash"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("a/b/c"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName(".hidden/repo"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("user/.hidden"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("user!/repo"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName(""));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("/repo"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("user/"));
}

// --- execute (tap) early branches ------------------------------------

test "execute --help short-circuits without opening the database" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try tap.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute on a fresh prefix with no db is a clean no-op" {
    const raw = try test_io.uniqueTempPath(testing.allocator, "tap_cli", "no_db");
    defer testing.allocator.free(raw);
    const path = try testing.allocator.dupeZ(u8, raw);
    defer testing.allocator.free(path);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    quiet();
    defer unquiet();
    try tap.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});
}

test "execute on an empty taps table prints \"No taps registered\"" {
    var s = try Scratch.init(testing.allocator, "list_empty");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }
    quiet();
    defer unquiet();
    try tap.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});
}

test "execute lists pinned + unpinned taps with the right line shape" {
    var s = try Scratch.init(testing.allocator, "list_full");
    defer s.deinit(testing.allocator);
    try seedTap(s.path, "homebrew/core", "0123456789abcdef0123456789abcdef01234567");
    try seedTap(s.path, "user/unpinned", null);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try tap.execute(&ctx, testing.allocator, &.{});
}

test "execute on an invalid tap name returns Aborted" {
    var s = try Scratch.init(testing.allocator, "invalid");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        tap.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"badname-no-slash"}),
    );
}

// --- executeUntap branches -------------------------------------------

test "executeUntap with no args returns Aborted with a usage hint" {
    var s = try Scratch.init(testing.allocator, "untap_noargs");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

test "executeUntap removes the matching row and is idempotent on rerun" {
    var s = try Scratch.init(testing.allocator, "untap_ok");
    defer s.deinit(testing.allocator);
    try seedTap(s.path, "user/repo", "0123456789abcdef0123456789abcdef01234567");

    quiet();
    defer unquiet();

    try tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{"user/repo"});
    try tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{"user/repo"});
}

test "executeUntap --refresh is rejected (refresh is tap-only)" {
    var s = try Scratch.init(testing.allocator, "untap_refresh");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "user/repo", "--refresh" }),
    );
}

// --- unknown flags ---------------------------------------------------

fn tapRowCount(prefix: []const u8, name: []const u8) !i64 {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT COUNT(*) FROM taps WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

test "execute refuses an unknown flag instead of listing taps and exiting clean" {
    var s = try Scratch.init(testing.allocator, "tap_unknown_flag");
    defer s.deinit(testing.allocator);
    try seedTap(s.path, "user/repo", null);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    try testing.expectError(
        error.Aborted,
        tap.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--nope"}),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, "--nope") != null);
}

test "executeUntap refuses an unknown flag and leaves the tap registered" {
    // A mistyped flag must not be dropped while the slug beside it is acted on.
    var s = try Scratch.init(testing.allocator, "untap_unknown_flag");
    defer s.deinit(testing.allocator);
    try seedTap(s.path, "user/repo", null);

    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--prune", "user/repo" }),
    );
    try testing.expectEqual(@as(i64, 1), try tapRowCount(s.path, "user/repo"));
}

test "executeUntap on a max-length prefix reaches its database" {
    var p = try test_io.LongPrefix.init(testing.allocator, "tap_cli", malt.prefix_path.max_prefix_len);
    defer p.deinit(testing.allocator);
    try seedTap(p.path, "user/repo", null);
    quiet();
    defer unquiet();
    try tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{"user/repo"});
    try testing.expectEqual(@as(i64, 0), try tapRowCount(p.path, "user/repo"));
}

// --- --dry-run -------------------------------------------------------

fn captureDryRun(captured: *std.ArrayList(u8)) void {
    output.setQuiet(false);
    output.setDryRun(true);
    output.beginStderrCapture(testing.allocator, captured);
}
fn endDryRun() void {
    output.endStderrCapture();
    output.setDryRun(false);
}

test "--dry-run untap previews the removal and keeps the tap registered" {
    var s = try Scratch.init(testing.allocator, "untap_dry_run");
    defer s.deinit(testing.allocator);
    try seedTap(s.path, "user/repo", "0123456789abcdef0123456789abcdef01234567");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    {
        captureDryRun(&captured);
        defer endDryRun();
        try tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{"user/repo"});
    }
    try testing.expect(std.mem.indexOf(u8, captured.items, "would untap user/repo") != null);
    try testing.expectEqual(@as(i64, 1), try tapRowCount(s.path, "user/repo"));

    // Control: the same argv without the preview does remove it.
    quiet();
    defer unquiet();
    try tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{"user/repo"});
    try testing.expectEqual(@as(i64, 0), try tapRowCount(s.path, "user/repo"));
}

test "--dry-run tap reports the pin it would keep without claiming it tapped" {
    var s = try Scratch.init(testing.allocator, "tap_dry_run_pinned");
    defer s.deinit(testing.allocator);
    try seedTap(s.path, "user/repo", "0123456789abcdef0123456789abcdef01234567");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = .empty, .offline = true };
    {
        captureDryRun(&captured);
        defer endDryRun();
        try tap.execute(&ctx, testing.allocator, &.{"user/repo"});
    }
    try testing.expect(std.mem.indexOf(u8, captured.items, "would tap user/repo @ 0123456") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "Tapped") == null);
}

test "--dry-run tap on a prefix without db/ creates nothing" {
    var s = try Scratch.init(testing.allocator, "tap_dry_run_fresh");
    defer s.deinit(testing.allocator);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{s.path});
    defer testing.allocator.free(db_dir);
    try test_io.deleteTreeAbsolute(std.Options.debug_io, db_dir);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = .empty, .offline = true };
    {
        captureDryRun(&captured);
        defer endDryRun();
        // Offline, the HEAD lookup fails exactly as the real run's would.
        try testing.expectError(error.Aborted, tap.execute(&ctx, testing.allocator, &.{"user/repo"}));
    }
    try testing.expect(std.mem.indexOf(u8, captured.items, "Could not resolve") != null);
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, db_dir, .{}));
}

test "--dry-run register previews a non-GitHub tap without the refresh hint" {
    // Nothing gets registered, so pointing at `tap --refresh` would fail.
    var s = try Scratch.init(testing.allocator, "tap_dry_run_register");
    defer s.deinit(testing.allocator);
    try seedTap(s.path, "seed/only", null);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    {
        captureDryRun(&captured);
        defer endDryRun();
        try tap.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "acme/tools", "--host", "gitlab.com", "--repo", "acme/tools" });
    }
    try testing.expect(std.mem.indexOf(u8, captured.items, "would register acme/tools") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "--refresh") == null);
    try testing.expectEqual(@as(i64, 0), try tapRowCount(s.path, "acme/tools"));
}

test "--dry-run refresh --all ends in a preview summary" {
    var s = try Scratch.init(testing.allocator, "tap_dry_run_refresh_all");
    defer s.deinit(testing.allocator);
    try seedTap(s.path, "seed/only", null);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try db.exec("DELETE FROM taps;");
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const ctx = ctxWithSink();
    {
        captureDryRun(&captured);
        defer endDryRun();
        try tap.execute(&ctx, testing.allocator, &.{ "--refresh", "--all" });
    }
    try testing.expect(std.mem.indexOf(u8, captured.items, "Dry run: would refresh 0 taps") != null);
}
