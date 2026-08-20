//! malt — rollback command tests
//! Integration tests for rollback require a full install cycle.
//! Unit tests here cover the DB query logic and the error-exit-code contract
//! (every user-facing failure must return `error.Aborted`, not a silent `void`).

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const sqlite = @import("malt").sqlite;
const schema = @import("malt").schema;
const rollback = @import("malt").cli_rollback;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setPrefix(v: [:0]const u8) void {
    _ = c.setenv("MALT_PREFIX", v.ptr, 1);
}
fn unsetPrefix() void {
    _ = c.unsetenv("MALT_PREFIX");
}

/// Per-process sandbox prefix. A shared `/tmp` path races with a concurrent
/// `zig build test` (or the ReleaseSafe regression harness) and fails the
/// WAL-mode open; keying on the pid keeps each runner isolated.
fn rbPrefix(buf: []u8, comptime name: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/malt_rb_{d}_" ++ name, .{std.c.getpid()}) catch unreachable;
}

/// Create a sandboxed malt prefix with an initialized empty DB. Caller must
/// `deleteTreeAbsolute` on the returned path.
fn makeSandbox(path: [:0]const u8) !void {
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, path);

    var db_sub_buf: [512]u8 = undefined;
    const db_sub = try std.fmt.bufPrint(&db_sub_buf, "{s}/db", .{path});
    try test_io.makeDirAbsolute(std.Options.debug_io, db_sub);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{path});
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);
}

test "schema creates kegs table with expected columns" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "test");
    test_io.makeDirAbsolute(std.Options.debug_io, prefix) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [96]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_buf, "{s}/rb.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    // Insert a keg and verify it can be queried
    try db.exec("INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason) VALUES ('wget', 'wget', '1.24', 0, 'homebrew/core', 'abc', '/tmp/cellar', 'direct');");

    var stmt = try db.prepare("SELECT name, version FROM kegs WHERE name = 'wget';");
    defer stmt.finalize();
    const has_row = try stmt.step();
    try testing.expect(has_row);

    const name = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("wget", std.mem.sliceTo(name, 0));
}

test "rollback returns error.Aborted when no package name given" {
    // Even without a prefix, the usage check fires first and must error.
    const err = rollback.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});
    try testing.expectError(error.Aborted, err);
}

test "rollback returns error.Aborted for package not installed" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "notinstalled");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    setPrefix(prefix);
    defer unsetPrefix();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    const args = [_][]const u8{"nonexistent-pkg"};
    const err = rollback.execute(&ctx, testing.allocator, &args);
    try testing.expectError(error.Aborted, err);
}

test "rollback returns error.Aborted when no previous version exists in store" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "nostore");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    // Record an installed keg but deliberately omit the store/ directory so
    // the store-scan path fails with "Cannot read store directory".
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    try db.exec("INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason) VALUES ('wget', 'wget', '1.24', 0, 'homebrew/core', 'deadbeef', '/tmp/none', 'direct');");
    db.close();

    setPrefix(prefix);
    defer unsetPrefix();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    const args = [_][]const u8{"wget"};
    const err = rollback.execute(&ctx, testing.allocator, &args);
    try testing.expectError(error.Aborted, err);
}

test "rollback distinguishes a cask token from a truly missing package" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "cask_diag");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    // Seed a cask row only — no matching keg. Pre-fix, the kegs-only
    // check claimed the cask was "not installed", which lied: it IS
    // installed, just not as a formula. This test pins the corrected
    // diagnostic so the lie doesn't quietly come back.
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    try db.exec(
        \\INSERT INTO casks (token, name, version, url, sha256)
        \\VALUES ('flux-markdown', 'flux-markdown', '1.32.427',
        \\        'https://example.invalid/flux.dmg', 'aa');
    );
    db.close();

    setPrefix(prefix);
    defer unsetPrefix();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &stderr_buf);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    const err = rollback.execute(&ctx, testing.allocator, &.{"flux-markdown"});
    try testing.expectError(error.Aborted, err);

    // The corrected diagnostic names the cask shape and steers the user
    // away from the "package is missing" mental model.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "cask") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "is not installed") == null);
}

test "schema version table exists" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "sv_test");
    test_io.makeDirAbsolute(std.Options.debug_io, prefix) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [96]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_buf, "{s}/sv.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    var stmt = try db.prepare("SELECT version FROM schema_version LIMIT 1;");
    defer stmt.finalize();
    const has_row = try stmt.step();
    try testing.expect(has_row);
}

// --- `--list` / `--to` integration ----------------------------------------

const output = malt.output;

/// Insert a current-keg row for `name` at `version` into the sandbox DB
/// so `execute` clears its "package not installed" guard.
fn insertCurrentKeg(prefix: [:0]const u8, name: []const u8, version: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    var stmt = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
        \\VALUES (?1, ?1, ?2, 0, 'cur-sha', '/cellar/x', 'direct');
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, version);
    _ = try stmt.step();
}

/// Seed a store entry tree `<prefix>/store/<sha>/<name>/<pkg_version>/` and
/// optionally sleep afterwards so two seeds get distinct mtimes on
/// second-resolution filesystems.
fn seedStoreEntry(
    prefix: [:0]const u8,
    sha: []const u8,
    name: []const u8,
    pkg_version: []const u8,
    delay_ms_after: u64,
) !void {
    const io = std.Options.debug_io;
    var buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "{s}/store/{s}/{s}/{s}", .{ prefix, sha, name, pkg_version });
    try test_io.cwd().createDirPath(io, dir);

    var f_buf: [600]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&f_buf, "{s}/INSTALL_RECEIPT.json", .{dir});
    const f = try test_io.createFileAbsolute(io, file_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "{}");

    if (delay_ms_after > 0) {
        test_io.sleepNanos(io, delay_ms_after * std.time.ns_per_ms);
    }
}

test "rollback --list prints every store entry available for the package" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "list_happy");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try insertCurrentKeg(prefix, "wget", "1.22");
    try seedStoreEntry(prefix, "sha_a", "wget", "1.20", 1100);
    try seedStoreEntry(prefix, "sha_b", "wget", "1.21", 1100);
    try seedStoreEntry(prefix, "sha_c", "wget", "1.22", 0); // current — must be excluded

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try rollback.execute(&ctx, testing.allocator, &.{ "--list", "wget" });

    const out = stdout_buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "wget") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.20") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.21") != null);
    // Current version is excluded from the listing.
    try testing.expect(std.mem.indexOf(u8, out, "1.22") == null);

    // Newest entry (sha_b/1.21) precedes the older one (sha_a/1.20).
    const v21 = std.mem.indexOf(u8, out, "1.21").?;
    const v20 = std.mem.indexOf(u8, out, "1.20").?;
    try testing.expect(v21 < v20);
}

test "rollback --list --json emits the documented JSON shape" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "list_json");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try insertCurrentKeg(prefix, "wget", "1.22");
    try seedStoreEntry(prefix, "sha_a", "wget", "1.20", 1100);
    try seedStoreEntry(prefix, "sha_b", "wget", "1.21", 0);

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    const prior = output.isJson();
    defer output.setMode(if (prior) .json else .human);
    output.setMode(.json);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try rollback.execute(&ctx, testing.allocator, &.{ "--list", "wget" });

    // Parseable JSON with the documented shape.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        std.mem.trimEnd(u8, stdout_buf.items, "\n"),
        .{},
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("wget", parsed.value.object.get("name").?.string);
    const arr = parsed.value.object.get("entries").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    // Sorted newest-first.
    try testing.expectEqualStrings("1.21", arr.items[0].object.get("version").?.string);
    try testing.expectEqualStrings("1.20", arr.items[1].object.get("version").?.string);
    // mtime is an integer (unix seconds), not a string.
    try testing.expect(arr.items[0].object.get("mtime").? == .integer);
}

test "rollback --to <current_version> is a clean no-op, not a confusing refusal" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "to_current");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try insertCurrentKeg(prefix, "wget", "1.22");
    try seedStoreEntry(prefix, "sha_a", "wget", "1.20", 1100);
    try seedStoreEntry(prefix, "sha_cur", "wget", "1.22", 0);

    setPrefix(prefix);
    defer unsetPrefix();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &stderr_buf);
    defer output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    // Asking to roll back to the version we're already on must succeed
    // (no mutation, no Aborted) so users can re-run the same command
    // idempotently inside scripts.
    try rollback.execute(&ctx, testing.allocator, &.{ "--to", "1.22", "wget" });

    // The "not in the store" refusal must NOT fire — that line is what we
    // explicitly do not want surfacing in this case.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "is not in the store") == null);
}

test "rollback --to <version> refuses with the listing when the version is absent" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "to_missing");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try insertCurrentKeg(prefix, "wget", "1.22");
    try seedStoreEntry(prefix, "sha_a", "wget", "1.20", 1100);
    try seedStoreEntry(prefix, "sha_b", "wget", "1.21", 0);

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    const err = rollback.execute(&ctx, testing.allocator, &.{ "--to", "9.9.9", "wget" });
    try testing.expectError(error.Aborted, err);

    const out = stdout_buf.items;
    // The refusal must surface the actual available versions so the user can pick one.
    try testing.expect(std.mem.indexOf(u8, out, "1.20") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.21") != null);
}

// --- cask `--list` / `--to` integration ---------------------------------

fn seedCask(prefix: [:0]const u8, token: []const u8, version: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare(
        \\INSERT INTO casks (token, name, version, url, sha256)
        \\VALUES (?1, ?1, ?2, 'https://example.invalid/x.dmg', 'aa');
    );
    defer stmt.finalize();
    try stmt.bindText(1, token);
    try stmt.bindText(2, version);
    _ = try stmt.step();
}

fn seedCaskVersion(prefix: [:0]const u8, token: []const u8, version: []const u8, installed_at: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare(
        \\INSERT INTO cask_versions (token, version, url, sha256, artifact_type, installed_at)
        \\VALUES (?1, ?2, 'https://example.invalid/x.dmg', 'aa', 'dmg', ?3);
    );
    defer stmt.finalize();
    try stmt.bindText(1, token);
    try stmt.bindText(2, version);
    try stmt.bindText(3, installed_at);
    _ = try stmt.step();
}

test "rollback <cask> --list lists every retained cask version" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "cask_list_happy");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try seedCask(prefix, "flux-markdown", "1.32.427");
    try seedCaskVersion(prefix, "flux-markdown", "1.30.0", "2026-01-01T00:00:00");
    try seedCaskVersion(prefix, "flux-markdown", "1.31.0", "2026-02-01T00:00:00");
    try seedCaskVersion(prefix, "flux-markdown", "1.32.427", "2026-03-01T00:00:00");

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try rollback.execute(&ctx, testing.allocator, &.{ "flux-markdown", "--list" });

    const out = stdout_buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "1.30.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.31.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.32.427") == null);

    const p31 = std.mem.indexOf(u8, out, "1.31.0").?;
    const p30 = std.mem.indexOf(u8, out, "1.30.0").?;
    try testing.expect(p31 < p30);
}

test "rollback <cask> --to <missing> refuses with the cask listing" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "cask_to_missing");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try seedCask(prefix, "flux-markdown", "1.32.427");
    try seedCaskVersion(prefix, "flux-markdown", "1.30.0", "2026-01-01T00:00:00");

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    const err = rollback.execute(&ctx, testing.allocator, &.{ "--to", "9.9.9", "flux-markdown" });
    try testing.expectError(error.Aborted, err);

    // Listing must accompany the refusal so the user knows which versions exist.
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "1.30.0") != null);
}

test "rollback <cask> --to <current> is an idempotent no-op" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "cask_to_current");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try seedCask(prefix, "flux-markdown", "1.32.427");
    try seedCaskVersion(prefix, "flux-markdown", "1.32.427", "2026-03-01T00:00:00");

    setPrefix(prefix);
    defer unsetPrefix();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    // Asking to roll back to the version already installed must succeed
    // without engaging the install pipeline.
    try rollback.execute(&ctx, testing.allocator, &.{ "flux-markdown", "--to", "1.32.427" });
}

test "rollback <cask> --to <ver> dry-run announces without engaging install" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "cask_dryrun");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try seedCask(prefix, "flux-markdown", "1.32.427");
    try seedCaskVersion(prefix, "flux-markdown", "1.30.0", "2026-01-01T00:00:00");

    setPrefix(prefix);
    defer unsetPrefix();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    // Dry-run must short-circuit before reinstall — proven by an invalid
    // URL not breaking the call (the real reinstall would error here).
    try rollback.execute(&ctx, testing.allocator, &.{ "--dry-run", "flux-markdown", "--to", "1.30.0" });
}

test "rollback <cask> (no flag) lands on the newest non-current entry" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "cask_default");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try seedCask(prefix, "flux-markdown", "1.32.427");
    try seedCaskVersion(prefix, "flux-markdown", "1.30.0", "2026-01-01T00:00:00");
    try seedCaskVersion(prefix, "flux-markdown", "1.31.0", "2026-02-01T00:00:00");

    setPrefix(prefix);
    defer unsetPrefix();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    // Default rollback (no --to) must engage the reinstall path; the
    // seeded URL is unreachable so the call surfaces error.Aborted.
    // The contract under test is that dispatch picks 1.31.0 (newest
    // non-current), not that the network round-trips.
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &stderr_buf);
    defer output.endStderrCapture();

    const err = rollback.execute(&ctx, testing.allocator, &.{"flux-markdown"});
    try testing.expectError(error.Aborted, err);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "1.31.0") != null);
}

test "rollback <cask> with empty history refuses with a useful diagnostic" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "cask_empty");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try seedCask(prefix, "flux-markdown", "1.32.427");
    // Only the current version exists in history.
    try seedCaskVersion(prefix, "flux-markdown", "1.32.427", "2026-03-01T00:00:00");

    setPrefix(prefix);
    defer unsetPrefix();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &stderr_buf);
    defer output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    const err = rollback.execute(&ctx, testing.allocator, &.{"flux-markdown"});
    try testing.expectError(error.Aborted, err);

    // The user must be told *why* there's nothing to roll back to.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "No previous version") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "1.32.427") != null);
}

// --- failed-rollback safety -----------------------------------------------

/// Seed a fully installed keg: Cellar tree, a linked `bin/` symlink, and the
/// matching `kegs` + `links` rows. Enough for `execute` to have something
/// real to destroy if the rollback isn't ordered correctly.
fn installKeg(prefix: [:0]const u8, name: []const u8, pkg_version: []const u8) !void {
    return installKegIsolated(prefix, name, pkg_version, false);
}

fn installKegIsolated(prefix: [:0]const u8, name: []const u8, pkg_version: []const u8, bin_isolated: bool) !void {
    return installKegAs(prefix, name, pkg_version, bin_isolated, "direct");
}

fn installKegAs(
    prefix: [:0]const u8,
    name: []const u8,
    pkg_version: []const u8,
    bin_isolated: bool,
    install_reason: []const u8,
) !void {
    const io = std.Options.debug_io;

    var keg_buf: [512]u8 = undefined;
    const keg_bin = try std.fmt.bufPrint(&keg_buf, "{s}/Cellar/{s}/{s}/bin", .{ prefix, name, pkg_version });
    try test_io.cwd().createDirPath(io, keg_bin);

    var exe_buf: [600]u8 = undefined;
    const exe = try std.fmt.bufPrint(&exe_buf, "{s}/{s}", .{ keg_bin, name });
    {
        const f = try test_io.createFileAbsolute(io, exe, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "#!/bin/sh\n");
    }

    var bin_dir_buf: [512]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_dir_buf, "{s}/bin", .{prefix});
    try test_io.cwd().createDirPath(io, bin_dir);

    var link_buf: [600]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/{s}", .{ bin_dir, name });
    try test_io.symLinkAbsolute(io, exe, link, .{});

    var cellar_buf: [512]u8 = undefined;
    const cellar_path = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, pkg_version });

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    {
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason, bin_isolated)
            \\VALUES (?1, ?1, ?2, 0, 'cur-sha', ?3, ?5, ?4);
        );
        defer stmt.finalize();
        try stmt.bindText(1, name);
        try stmt.bindText(2, pkg_version);
        try stmt.bindText(3, cellar_path);
        try stmt.bindInt(4, @intFromBool(bin_isolated));
        try stmt.bindText(5, install_reason);
        _ = try stmt.step();
    }
    {
        var stmt = try db.prepare(
            "INSERT INTO links (keg_id, link_path, target) VALUES (last_insert_rowid(), ?1, ?2);",
        );
        defer stmt.finalize();
        try stmt.bindText(1, link);
        try stmt.bindText(2, exe);
        _ = try stmt.step();
    }
}

/// Deny all access to a store keg dir so `materializeWithCellar` fails the
/// way a corrupt or unreadable store entry does, without deleting it (the
/// entry has to stay discoverable by `collectEntries`).
fn denyAccess(prefix: [:0]const u8, sha: []const u8, name: []const u8, pkg_version: []const u8, mode: c_uint) void {
    var buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&buf, "{s}/store/{s}/{s}/{s}", .{ prefix, sha, name, pkg_version }) catch return;
    _ = std.c.chmod(dir.ptr, @intCast(mode));
}

fn installedVersion(prefix: [:0]const u8, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    var stmt = try db.prepare("SELECT version FROM kegs WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    if (!(try stmt.step())) return allocator.dupe(u8, "");
    const v = stmt.columnText(0) orelse return allocator.dupe(u8, "");
    return allocator.dupe(u8, std.mem.sliceTo(v, 0));
}

// The failure this pins: rollback used to unlink and delete the current keg
// before the fallible materialize, so a bad store entry left the machine with
// no working version and a DB row pointing at nothing.
test "a rollback that cannot materialize leaves the current version installed" {
    if (std.c.geteuid() == 0) return error.SkipZigTest; // chmod 000 doesn't bite root

    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "materialize_fail");
    try makeSandbox(prefix);
    defer {
        denyAccess(prefix, "sha_old", "wget", "1.20", 0o755);
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    }

    try installKeg(prefix, "wget", "1.22");
    try seedStoreEntry(prefix, "sha_old", "wget", "1.20", 0);
    denyAccess(prefix, "sha_old", "wget", "1.20", 0o000);

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(error.Aborted, rollback.execute(&ctx, testing.allocator, &.{"wget"}));

    const io = std.Options.debug_io;
    var buf: [512]u8 = undefined;

    const cellar = try std.fmt.bufPrint(&buf, "{s}/Cellar/wget/1.22", .{prefix});
    try test_io.accessAbsolute(io, cellar, .{});

    var buf2: [512]u8 = undefined;
    const link = try std.fmt.bufPrint(&buf2, "{s}/bin/wget", .{prefix});
    try test_io.accessAbsolute(io, link, .{});

    const ver = try installedVersion(prefix, testing.allocator, "wget");
    defer testing.allocator.free(ver);
    try testing.expectEqualStrings("1.22", ver);
}

fn kegFlag(prefix: [:0]const u8, name: []const u8, column: []const u8) !bool {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    var sql_buf: [128]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&sql_buf, "SELECT {s} FROM kegs WHERE name = ?1;", .{column});
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    try stmt.bindText(1, name);
    if (!(try stmt.step())) return error.TestUnexpectedResult;
    return stmt.columnBool(0);
}

// Pins the whole happy path plus the columns the row swap has to carry:
// a bin-isolated, held keg must come back bin-isolated and still held.
test "a completed rollback preserves bin isolation and the hold" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "carry_flags");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try installKegIsolated(prefix, "wget", "1.22", true);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try db.exec("UPDATE kegs SET pinned = 1 WHERE name = 'wget';");
    }
    try seedStoreEntry(prefix, "sha_old", "wget", "1.20", 0);

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try rollback.execute(&ctx, testing.allocator, &.{"wget"});

    const ver = try installedVersion(prefix, testing.allocator, "wget");
    defer testing.allocator.free(ver);
    try testing.expectEqualStrings("1.20", ver);

    try testing.expect(try kegFlag(prefix, "wget", "bin_isolated"));
    try testing.expect(try kegFlag(prefix, "wget", "pinned"));

    // The version we rolled away from is gone from disk only after the swap.
    const io = std.Options.debug_io;
    var buf: [512]u8 = undefined;
    const old_cellar = try std.fmt.bufPrint(&buf, "{s}/Cellar/wget/1.22", .{prefix});
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(io, old_cellar, .{}));

    // Dependents resolve through opt/, so it has to follow the rollback.
    var opt_buf: [512]u8 = undefined;
    const opt_link = try std.fmt.bufPrint(&opt_buf, "{s}/opt/wget", .{prefix});
    var target_buf: [512]u8 = undefined;
    const opt_target = try test_io.readLinkAbsolute(io, opt_link, &target_buf);
    try testing.expect(std.mem.endsWith(u8, opt_target, "/Cellar/wget/1.20"));
}

fn kegInstallReason(prefix: [:0]const u8, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    var stmt = try db.prepare("SELECT install_reason FROM kegs WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    if (!(try stmt.step())) return error.TestUnexpectedResult;
    const r = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    return allocator.dupe(u8, std.mem.sliceTo(r, 0));
}

// A keg pulled in as a dependency stays reclaimable after a rollback:
// relabelling it 'direct' would make autoremove skip it forever.
test "rolling back a dependency keeps it marked as a dependency" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "carry_reason");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try installKegAs(prefix, "pcre2", "10.45", false, "dependency");
    try seedStoreEntry(prefix, "sha_old", "pcre2", "10.44", 0);

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try rollback.execute(&ctx, testing.allocator, &.{"pcre2"});

    const reason = try kegInstallReason(prefix, testing.allocator, "pcre2");
    defer testing.allocator.free(reason);
    try testing.expectEqualStrings("dependency", reason);
}

fn depNames(prefix: [:0]const u8, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    var stmt = try db.prepare(
        \\SELECT d.dep_name FROM dependencies d
        \\JOIN kegs k ON k.id = d.keg_id WHERE k.name = ?1 ORDER BY d.dep_name;
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (try stmt.step()) {
        const n = stmt.columnText(0) orelse continue;
        if (out.items.len > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, std.mem.sliceTo(n, 0));
    }
    return out.toOwnedSlice(allocator);
}

fn addDep(prefix: [:0]const u8, name: []const u8, dep: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    var stmt = try db.prepare(
        "INSERT INTO dependencies (keg_id, dep_name) SELECT id, ?2 FROM kegs WHERE name = ?1;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, dep);
    _ = try stmt.step();
}

// Without this the rolled-back keg has no recorded dependencies, and the
// next cleanup reclaims the packages it still links against.
test "a completed rollback keeps the keg's dependency edges" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "carry_deps");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try installKeg(prefix, "wget", "1.22");
    try addDep(prefix, "wget", "openssl@3");
    try addDep(prefix, "wget", "libidn2");
    try seedStoreEntry(prefix, "sha_old", "wget", "1.20", 0);

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try rollback.execute(&ctx, testing.allocator, &.{"wget"});

    const deps = try depNames(prefix, testing.allocator, "wget");
    defer testing.allocator.free(deps);
    try testing.expectEqualStrings("libidn2,openssl@3", deps);
}

/// Park a decoy keg row on the version we are about to roll back to, so the
/// swap's INSERT trips `UNIQUE(name, version, revision)` after `unlink` has
/// already torn the current version's symlinks down.
fn seedColliding(prefix: [:0]const u8, name: []const u8, version: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    var stmt = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, installed_at)
        \\VALUES (?1, ?1, ?2, 0, 'sha-decoy', '/c/decoy', '1970-01-01 00:00:00');
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, version);
    _ = try stmt.step();
}

// The restore half of the fix: once `unlink` has run, a failing swap has to
// put the current version's symlinks back and drop the half-installed target.
test "a rollback that fails mid-swap restores the current version's links" {
    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "swap_fail");
    try makeSandbox(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try installKeg(prefix, "wget", "1.22");
    try seedStoreEntry(prefix, "sha_old", "wget", "1.20", 0);
    try seedColliding(prefix, "wget", "1.20");

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(error.Aborted, rollback.execute(&ctx, testing.allocator, &.{"wget"}));

    const io = std.Options.debug_io;

    // The symlink `unlink` removed is back on disk...
    var link_buf: [512]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/bin/wget", .{prefix});
    try test_io.accessAbsolute(io, link, .{});

    // ...and so is its DB row, courtesy of the transaction rollback.
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        var stmt = try db.prepare("SELECT COUNT(*) FROM links WHERE link_path = ?1;");
        defer stmt.finalize();
        try stmt.bindText(1, link);
        _ = try stmt.step();
        try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    }

    // The current version's Cellar tree was never touched...
    var cur_buf: [512]u8 = undefined;
    const cur_cellar = try std.fmt.bufPrint(&cur_buf, "{s}/Cellar/wget/1.22", .{prefix});
    try test_io.accessAbsolute(io, cur_cellar, .{});

    // ...and the half-installed target was cleaned up.
    var new_buf: [512]u8 = undefined;
    const new_cellar = try std.fmt.bufPrint(&new_buf, "{s}/Cellar/wget/1.20", .{prefix});
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(io, new_cellar, .{}));
}

/// Make a keg dir's contents un-unlinkable so `cellar.remove` fails without
/// affecting anything else in the prefix.
fn freezeKegDir(prefix: [:0]const u8, name: []const u8, pkg_version: []const u8, mode: c_uint) void {
    var buf: [512]u8 = undefined;
    const bin = std.fmt.bufPrintZ(&buf, "{s}/Cellar/{s}/{s}/bin", .{ prefix, name, pkg_version }) catch return;
    _ = std.c.chmod(bin.ptr, @intCast(mode));
    var buf2: [512]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&buf2, "{s}/Cellar/{s}/{s}", .{ prefix, name, pkg_version }) catch return;
    _ = std.c.chmod(dir.ptr, @intCast(mode));
}

// Sweeping the replaced version is housekeeping, not part of the swap: if it
// fails the user still has a working, correctly recorded package and only
// garbage is left behind.
test "a rollback still succeeds when the old cellar dir cannot be removed" {
    if (std.c.geteuid() == 0) return error.SkipZigTest; // chmod doesn't deny root

    var pbuf: [64]u8 = undefined;
    const prefix = rbPrefix(&pbuf, "stuck_cellar");
    try makeSandbox(prefix);
    defer {
        freezeKegDir(prefix, "wget", "1.22", 0o755);
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    }

    try installKeg(prefix, "wget", "1.22");
    try seedStoreEntry(prefix, "sha_old", "wget", "1.20", 0);
    freezeKegDir(prefix, "wget", "1.22", 0o500);

    setPrefix(prefix);
    defer unsetPrefix();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &stderr_buf);
    defer output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try rollback.execute(&ctx, testing.allocator, &.{"wget"});

    // The rollback itself landed...
    const ver = try installedVersion(prefix, testing.allocator, "wget");
    defer testing.allocator.free(ver);
    try testing.expectEqualStrings("1.20", ver);

    const io = std.Options.debug_io;
    var buf: [512]u8 = undefined;
    const new_cellar = try std.fmt.bufPrint(&buf, "{s}/Cellar/wget/1.20", .{prefix});
    try test_io.accessAbsolute(io, new_cellar, .{});

    // ...the stale dir is all that is left behind...
    const old_cellar = try std.fmt.bufPrint(&buf, "{s}/Cellar/wget/1.22", .{prefix});
    try test_io.accessAbsolute(io, old_cellar, .{});

    // ...and the user was told about it.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Could not remove cellar entry") != null);
}
