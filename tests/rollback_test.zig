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
    const prefix = "/tmp/malt_rb_test";
    test_io.makeDirAbsolute(std.Options.debug_io, prefix) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db = try sqlite.Database.open("/tmp/malt_rb_test/rb.db");
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_notinstalled";
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_nostore";
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

test "capturePinnedById reads the pinned column for a given keg id" {
    const prefix = "/tmp/malt_rb_capture_pin";
    test_io.makeDirAbsolute(std.Options.debug_io, prefix) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db = try sqlite.Database.open("/tmp/malt_rb_capture_pin/db.db");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned)
        \\VALUES ('held', 'held', '1.0', 'sha', '/cellar/held/1.0', 1),
        \\       ('loose', 'loose', '1.0', 'sha2', '/cellar/loose/1.0', 0);
    );

    const held_id = blk: {
        var s = try db.prepare("SELECT id FROM kegs WHERE name = 'held';");
        defer s.finalize();
        _ = try s.step();
        break :blk s.columnInt(0);
    };
    const loose_id = blk: {
        var s = try db.prepare("SELECT id FROM kegs WHERE name = 'loose';");
        defer s.finalize();
        _ = try s.step();
        break :blk s.columnInt(0);
    };

    try testing.expect(rollback.capturePinnedById(&db, held_id));
    try testing.expect(!rollback.capturePinnedById(&db, loose_id));
    // Unknown id collapses to false rather than erroring — matches the
    // "best-effort, never lose data" stance the rollback flow needs.
    try testing.expect(!rollback.capturePinnedById(&db, 999_999));
}

test "rollback distinguishes a cask token from a truly missing package" {
    const prefix: [:0]const u8 = "/tmp/malt_rb_cask_diag";
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
    const prefix = "/tmp/malt_sv_test";
    test_io.makeDirAbsolute(std.Options.debug_io, prefix) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db = try sqlite.Database.open("/tmp/malt_sv_test/sv.db");
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_list_happy";
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_list_json";
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_to_current";
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_to_missing";
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_cask_list_happy";
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_cask_to_missing";
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_cask_to_current";
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_cask_dryrun";
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_cask_default";
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
    const prefix: [:0]const u8 = "/tmp/malt_rb_cask_empty";
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
