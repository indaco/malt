//! malt — upgrade.execute behaviour tests
//! Locks in the exit-code contract: an upgrade that touches a package we
//! cannot upgrade (not installed, or batch item failure) must surface a
//! non-zero exit instead of silently reporting success. Uses a scratch
//! MALT_PREFIX so no real DB or network is hit.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const upgrade = malt.upgrade;
const install = malt.install;
const install_record = malt.install_record;
const sqlite = malt.sqlite;
const schema = malt.schema;
const formula_mod = malt.formula;
const lock_mod = malt.lock;
const output = malt.output;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const base = try test_io.uniqueTempPath(testing.allocator, "upgrade_exec", suffix);
    defer testing.allocator.free(base);
    const path = try testing.allocator.dupeZ(u8, base);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "mt upgrade <nonexistent> surfaces a non-zero exit" {
    const path = try setupPrefix("nonexistent_pkg");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // Seed an empty DB so the `db/` dir exists (lock acquire doesn't
    // short-circuit to silent-return) but no packages are installed.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        upgrade.execute(&ctx, testing.allocator, &.{"definitely-not-installed"}),
    );
}

fn openSeededDb(prefix: [:0]const u8) !sqlite.Database {
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

    var buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    errdefer db.close();
    try schema.initSchema(&db);
    return db;
}

fn insertPinnedKeg(db: *sqlite.Database, name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('{s}', '{s}', '1.0', 'deadbeef', '/cellar/{s}/1.0', 1);",
        .{ name, name, name },
    );
    try db.exec(sql);
}

test "mt upgrade <pinned> is a quiet no-op (no API call)" {
    const path = try setupPrefix("pinned_skip_named");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertPinnedKeg(&db, "alpha-pinned");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    // Pinned name short-circuits before fetchFormula — must NOT error.
    try upgrade.execute(&ctx, testing.allocator, &.{"alpha-pinned"});
}

test "mt upgrade (no args) skips pinned kegs without aggregating failures" {
    const path = try setupPrefix("pinned_skip_bulk");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertPinnedKeg(&db, "first-pinned");
        try insertPinnedKeg(&db, "second-pinned");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    // All-pinned bulk run: every keg is skipped, no failures aggregate.
    try upgrade.execute(&ctx, testing.allocator, &.{});
}

test "mt upgrade --pinned --dry-run with no pinned kegs is a quiet no-op" {
    const path = try setupPrefix("pinned_audit_empty");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        // Unpinned keg — the --pinned filter excludes it, no API call.
        try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('loose', 'loose', '1.0', 'sha', '/cellar/loose/1.0');");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try upgrade.execute(&ctx, testing.allocator, &.{ "--pinned", "--dry-run" });
}

test "mt upgrade --pinned without --dry-run or --force errors with usage" {
    const path = try setupPrefix("pinned_requires_audit");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        upgrade.execute(&ctx, testing.allocator, &.{"--pinned"}),
    );
}

fn insertPinnedCask(db: *sqlite.Database, token: []const u8, version: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO casks (token, name, version, url, pinned) VALUES ('{s}', '{s}', '{s}', 'https://example.invalid', 1);",
        .{ token, token, version },
    );
    try db.exec(sql);
}

test "mt upgrade <pinned-cask> is a quiet no-op (no API call)" {
    const path = try setupPrefix("pinned_skip_named_cask");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertPinnedCask(&db, "firefox", "120.0");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    // Pinned cask short-circuits in upgradeCask before fetchCask — must NOT error.
    try upgrade.execute(&ctx, testing.allocator, &.{"firefox"});
}

test "recordKeg inherits pinned=1 from an existing keg of the same name" {
    const path = try setupPrefix("recordkeg_inherit_pin");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertPinnedKeg(&db, "alpha");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json =
        \\{
        \\  "name": "alpha",
        \\  "full_name": "alpha",
        \\  "tap": "homebrew/core",
        \\  "versions": {"stable": "2.0"}
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    const new_keg_id = try install_record.recordKeg(&db, &formula, "deadbeef2", "/cellar/alpha/2.0", "direct", false, .{});

    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE id = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_keg_id);
    _ = try stmt.step();
    try testing.expectEqual(true, stmt.columnBool(0));
}

test "force-upgrade-cask orchestration: pin survives removeRecord + recordInstall" {
    // Simulates the DB side of upgradeCask under --force: the existing
    // pinned cask row is removed (uninstall.removeRecord), a new row is
    // inserted (recordInstall), and the orchestration must reapply the
    // pin so the user's hold survives.
    const path = try setupPrefix("force_upgrade_cask_pin");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertPinnedCask(&db, "firefox", "1.0");

    const was_pinned = malt.cli_pin.isPinned(&db, "firefox");
    try testing.expect(was_pinned);

    // Step 1: uninstall side — DB row removed by removeRecord.
    try malt.cask.removeRecord(&db, "firefox");

    // Step 2: install side — recordInstall on a fresh row defaults pinned=0.
    var c2 = try malt.cask.parseCask(testing.allocator,
        \\{
        \\  "token": "firefox",
        \\  "name": ["Firefox"],
        \\  "version": "200.0",
        \\  "url": "https://example.invalid/firefox.dmg",
        \\  "auto_updates": true,
        \\  "artifacts": [{"app": ["Firefox.app"]}]
        \\}
    );
    defer c2.deinit();
    try malt.cask.recordInstall(&db, &c2, "/Applications/Firefox.app", null);

    // Step 3: orchestration must reapply the pin.
    if (was_pinned) {
        _ = try malt.cli_pin.setPinned(&db, "firefox", true);
    }

    try testing.expect(malt.cli_pin.isPinned(&db, "firefox"));
}

test "recordKeg defaults pinned=0 when no prior keg of that name exists" {
    const path = try setupPrefix("recordkeg_fresh_pin");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json =
        \\{
        \\  "name": "fresh",
        \\  "full_name": "fresh",
        \\  "tap": "homebrew/core",
        \\  "versions": {"stable": "1.0"}
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    const new_keg_id = try install_record.recordKeg(&db, &formula, "deadbeef0", "/cellar/fresh/1.0", "direct", false, .{});

    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE id = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_keg_id);
    _ = try stmt.step();
    try testing.expectEqual(false, stmt.columnBool(0));
}

// Atomicity contract: recordKeg participates in an enclosing transaction
// rather than starting its own. Without this, upgradeFormula cannot wrap
// unlink+recordKeg+link in a single txn — the inner BEGIN IMMEDIATE
// would error with "cannot start a transaction within a transaction"
// and leave the DB half-mutated on partial failure.
test "recordKeg runs inside an outer beginTransaction without nesting errors" {
    const path = try setupPrefix("recordkeg_inside_outer_txn");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json =
        \\{
        \\  "name": "inside-txn",
        \\  "full_name": "inside-txn",
        \\  "tap": "homebrew/core",
        \\  "versions": {"stable": "2.0"}
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    try db.beginTransaction();
    const new_keg_id = try install_record.recordKeg(&db, &formula, "sha-inner", "/cellar/inside-txn/2.0", "direct", false, .{ .in_transaction = true });
    try db.commit();

    var stmt = try db.prepare("SELECT name, version FROM kegs WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_keg_id);
    _ = try stmt.step();
    try testing.expectEqualStrings("inside-txn", std.mem.sliceTo(stmt.columnText(0).?, 0));
    try testing.expectEqualStrings("2.0", std.mem.sliceTo(stmt.columnText(1).?, 0));
}

// Re-record contract: an `INSERT OR REPLACE` on the kegs UNIQUE
// (name, version, revision) drops the old row in place and the new
// row carries fresh `store_sha256` / `cellar_path` values. Force
// re-install relies on this — without OR REPLACE the user would
// see a hard error instead of the expected reinstall.
test "recordKeg INSERT OR REPLACE rewrites an existing (name,version,revision)" {
    const path = try setupPrefix("recordkeg_replace_same_key");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('collide', 'collide', '1.0', 0, 'sha-old', '/cellar/collide/1.0');
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json =
        \\{
        \\  "name": "collide",
        \\  "full_name": "collide",
        \\  "tap": "homebrew/core",
        \\  "versions": {"stable": "1.0"}
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    const new_keg_id = try install_record.recordKeg(&db, &formula, "sha-new", "/cellar/collide/1.0", "direct", false, .{});

    var count_stmt = try db.prepare("SELECT COUNT(*) FROM kegs WHERE name='collide';");
    defer count_stmt.finalize();
    _ = try count_stmt.step();
    try testing.expectEqual(@as(i64, 1), count_stmt.columnInt(0));

    var sha_stmt = try db.prepare("SELECT store_sha256 FROM kegs WHERE id = ?1;");
    defer sha_stmt.finalize();
    try sha_stmt.bindInt(1, new_keg_id);
    _ = try sha_stmt.step();
    try testing.expectEqualStrings("sha-new", std.mem.sliceTo(sha_stmt.columnText(0).?, 0));
}

// Atomic-txn contract is now structural: `upgradeDbAtomic` is a flat
// `try`-chain inside the caller's BEGIN/COMMIT, so any failure (linker,
// SQLite, FS) short-circuits and the outer ROLLBACK reverts every
// mutation made so far. Pre-T-007 the test crafted a `recordKeg` UNIQUE
// collision to drive the unhappy path; the unified `INSERT OR REPLACE`
// eliminates that trigger and there is no contrived in-DB failure left
// to inject. End-to-end coverage lives in
// `scripts/regressions/upgrade_atomic_db_rollback.sh`.

test "pinSkip honours --force and audit_mode for casks too" {
    const path = try setupPrefix("pinskip_cask");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertPinnedCask(&db, "held-cask", "1.0");

    try testing.expect(upgrade.pinSkip(&db, "held-cask", false, false));
    try testing.expect(!upgrade.pinSkip(&db, "held-cask", true, false));
    try testing.expect(!upgrade.pinSkip(&db, "held-cask", false, true));
}

test "mt upgrade --pinned --dry-run reaches the cask path (no formula-only override)" {
    const path = try setupPrefix("pinned_audit_cask");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertPinnedCask(&db, "pinned-cask", "1.0");
    }

    // No cache seeded: if the walker reaches the cask, fetchCask fails and
    // aborts; if the formula-only override is still in place, the cask
    // path is silently skipped and execute() returns OK. The audit must
    // walk the row, so this run aborts.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        upgrade.execute(&ctx, testing.allocator, &.{ "--pinned", "--dry-run" }),
    );
}

test "pinSkip honours --force and audit_mode: pinned + override = no skip" {
    const path = try setupPrefix("pinskip_helper");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertPinnedKeg(&db, "forced");
    try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('loose', 'loose', '1.0', 'sha', '/cellar/loose/1.0');");

    // pinned + neither override = skip
    try testing.expect(upgrade.pinSkip(&db, "forced", false, false));
    // pinned + force = no skip (the whole point of --force)
    try testing.expect(!upgrade.pinSkip(&db, "forced", true, false));
    // pinned + audit = no skip (so `--pinned --dry-run` walks the row)
    try testing.expect(!upgrade.pinSkip(&db, "forced", false, true));
    // unpinned: never skipped, force/audit or not
    try testing.expect(!upgrade.pinSkip(&db, "loose", false, false));
    try testing.expect(!upgrade.pinSkip(&db, "loose", true, false));
    // unknown name: not pinned, not skipped
    try testing.expect(!upgrade.pinSkip(&db, "ghost", false, false));
}

// Regression: a Homebrew revision-bump upgrade leaves the old keg row
// in place until step 8 of upgradeFormula, so recordKeg's INSERT must
// not collide with it on (name, version) when only `revision` differs.
// Pre-fix this aborted with SQLITE_CONSTRAINT_UNIQUE → "Failed to
// record new version of <name> in database" — the bug from the user
// report on libgit2 1.9.2 → 1.9.2_2 and python@3.14 3.14.4 → 3.14.4_1.
test "recordKeg succeeds on a same-version revision-bump upgrade" {
    const path = try setupPrefix("recordkeg_revision_bump");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();

    // Old row matches what `mt install libgit2` writes for revision 0:
    // version='1.9.2', revision unset → defaults to 0.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES ('libgit2', 'libgit2', '1.9.2', 'sha-old', '/cellar/libgit2/1.9.2');
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // revision: 2 → pkg_version "1.9.2_2"; upstream `version` stays "1.9.2".
    const formula_json =
        \\{
        \\  "name": "libgit2",
        \\  "full_name": "libgit2",
        \\  "tap": "homebrew/core",
        \\  "revision": 2,
        \\  "versions": {"stable": "1.9.2"}
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    const new_keg_id = try install_record.recordKeg(&db, &formula, "sha-new", "/cellar/libgit2/1.9.2_2", "direct", false, .{});

    // Both rows must coexist briefly — upgradeFormula deletes the old
    // one in step 8, after symlinks flip to the new keg.
    var stmt = try db.prepare("SELECT COUNT(*) FROM kegs WHERE name='libgit2';");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 2), stmt.columnInt(0));

    var rev_stmt = try db.prepare("SELECT revision FROM kegs WHERE id = ?1;");
    defer rev_stmt.finalize();
    try rev_stmt.bindInt(1, new_keg_id);
    _ = try rev_stmt.step();
    try testing.expectEqual(@as(i64, 2), rev_stmt.columnInt(0));
}

// Regression: upgrade.execute holds malt.lock on its own fd, then re-enters
// install.execute via installAll for missing transitive deps. BSD flock is
// per-fd, so the inner acquire EAGAIN-loops 30 s on the outer process's own
// hold and aborts with the misleading "Another mt process is running" error.
// installAll exposes `skip_lock = true` for callers that already own the
// lock; this test pins that contract from the install side and the upgrade
// side asserts the same path completes without a lock-contention message.
test "installAll honours skip_lock so an outer holder can re-enter without a self-deadlock" {
    const path = try setupPrefix("installall_skip_lock");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

    // Plant 404 markers for both formula and cask kinds so resolution
    // exits before the network is reached and no jobs queue up.
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{path});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    inline for (.{ "formula_zzghost.404", "cask_zzghost.404" }) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ cache_api, name });
        defer testing.allocator.free(p);
        const f = try test_io.createFileAbsolute(std.Options.debug_io, p, .{ .truncate = true });
        f.close(std.Options.debug_io);
    }

    // Mimic the outer hold that upgrade.execute already owns.
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{path});
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var outer = try lock_mod.LockFile.acquire(ctx.io, lock_path, 1000);
    defer outer.release(ctx.io);

    output.setQuiet(true);
    defer output.setQuiet(false);

    // skip_lock=true must bypass the per-fd flock entirely. The 404
    // markers force the formula→cask fall-through to fail, so the
    // dispatcher surfaces PartialFailure — proving we reached resolution
    // (i.e. never blocked on the lock) while exiting with the right code.
    try testing.expectError(
        install_record.InstallError.PartialFailure,
        install.installAll(&ctx, testing.allocator, &.{"zzghost"}, .{ .skip_lock = true }),
    );
}

// Regression: when the new bottle of an installed formula introduces a dep
// that isn't on disk yet, upgrade.execute reaches into installAll to fetch
// the missing dep. The path used to deadlock against its own malt.lock and
// surface as "Another mt process is running"; the user-facing fix is that
// the dep install branch exits via its own diagnostic instead.
test "upgrade with a missing transitive dep does not error with lock contention" {
    const path = try setupPrefix("upgrade_missing_dep");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
            \\VALUES ('curl', 'curl', '8.19', 'sha-old', '/cellar/curl/8.19');
        );
    }

    // Cache-seed the new curl JSON with a dep on a name that 404s, so the
    // dep installAll exits via "fetchFormula failed" rather than network.
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{path});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);

    const cache_json = try std.fmt.allocPrint(testing.allocator, "{s}/formula_curl.json", .{cache_api});
    defer testing.allocator.free(cache_json);
    const cf = try test_io.createFileAbsolute(std.Options.debug_io, cache_json, .{ .truncate = true });
    const body =
        \\{"name":"curl","full_name":"curl","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"8.20"},"dependencies":["zzngtcp2"],"oldnames":[],"bottle":{"stable":{"root_url":"","files":{}}}}
    ;
    try cf.writeStreamingAll(std.Options.debug_io, body);
    cf.close(std.Options.debug_io);

    inline for (.{ "formula_zzngtcp2.404", "cask_zzngtcp2.404" }) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ cache_api, name });
        defer testing.allocator.free(p);
        const m = try test_io.createFileAbsolute(std.Options.debug_io, p, .{ .truncate = true });
        m.close(std.Options.debug_io);
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    // The bottle slot is empty so resolveBottle aborts after the dep
    // install path runs — both branches surface error.Aborted today, but
    // the load-bearing observation is the *reason*: the error must not be
    // the lock-contention message that masks the real cause.
    upgrade.execute(&ctx, testing.allocator, &.{"curl"}) catch {};

    try testing.expect(std.mem.indexOf(u8, captured.items, "Another mt process is running") == null);
}

// Pre-fix, every keg row went through `formulae.brew.sh/api/formula/<name>.json`,
// so a tap-installed package surfaced as `Could not fetch formula info for X` and
// error.Aborted - even though the package never lived on the core API. The new
// upgrade path consults `kegs.tap` and routes anything off `homebrew/core` through
// the tap-aware branch instead. The malformed-label case below pins the routing:
// the old API error must NOT appear, because we exit on the tap-side parse check.
test "upgrade routes tap-installed kegs away from the core formula API" {
    const path = try setupPrefix("upgrade_tap_routing");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        // Tap label is intentionally malformed (no slash) so the tap-side
        // parser rejects it before any network call and we never touch the
        // core API regardless of cache state.
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, tap, store_sha256, cellar_path)
            \\VALUES ('baguette', 'tap-only/repo/baguette', '0.1', 'tap-only-no-slash', 'sha-old', '/cellar/baguette/0.1');
        );
    }

    // Seed a 404 marker for the core API so the OLD codepath would have
    // surfaced "Could not fetch formula info" without touching the network.
    // The NEW codepath must never read this marker.
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{path});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_baguette.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try test_io.createFileAbsolute(std.Options.debug_io, marker, .{ .truncate = true });
    mf.close(std.Options.debug_io);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    try testing.expectError(
        error.Aborted,
        upgrade.execute(&ctx, testing.allocator, &.{"baguette"}),
    );

    // Routing guard: the OLD core-API error must never appear for a tap keg.
    try testing.expect(std.mem.indexOf(u8, captured.items, "Could not fetch formula info") == null);
    // Positive signal: the tap-side parser rejected the malformed label.
    try testing.expect(std.mem.indexOf(u8, captured.items, "Cannot parse tap") != null);
}

// A pinned tap-installed keg short-circuits in pinSkip before any network
// activity - same contract as a pinned core keg, just on the tap branch.
// Materialise `<prefix>/Cellar/<name>/<version>` on disk and (optionally)
// the matching `<prefix>/opt/<name>` symlink, then insert the matching
// keg row. Mirrors what the install path leaves behind so
// `deps.isInstalled`'s opt-link + cellar-path probe sees a healthy keg.
fn seedInstalledKeg(
    db: *sqlite.Database,
    prefix: []const u8,
    name: []const u8,
    version: []const u8,
    create_opt_link: bool,
) !void {
    var cellar_buf: [512]u8 = undefined;
    const cellar_root = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar_root);

    var insert_buf: [512]u8 = undefined;
    const insert = try std.fmt.bufPrintZ(
        &insert_buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('{s}', '{s}', '{s}', 'sha-{s}', '{s}');",
        .{ name, name, version, name, cellar_root },
    );
    try db.exec(insert);

    if (!create_opt_link) return;

    var opt_dir_buf: [512]u8 = undefined;
    const opt_dir = try std.fmt.bufPrint(&opt_dir_buf, "{s}/opt", .{prefix});
    try test_io.cwd().createDirPath(std.Options.debug_io, opt_dir);

    var opt_path_buf: [512]u8 = undefined;
    const opt_path = try std.fmt.bufPrint(&opt_path_buf, "{s}/{s}", .{ opt_dir, name });
    var parent = try test_io.openDirAbsolute(std.Options.debug_io, opt_dir, .{});
    defer parent.close(std.Options.debug_io);
    parent.deleteFile(std.Options.debug_io, name) catch {};
    try parent.symLink(std.Options.debug_io, cellar_root, name, .{});
    _ = opt_path;
}

test "collectMissingDepNames returns names absent from the DB" {
    const path = try setupPrefix("missing_deps_absent");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try seedInstalledKeg(&db, path, "alpha", "1.0", true);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const deps = [_][]const u8{ "alpha", "beta", "gamma" };
    const missing = try upgrade.collectMissingDepNames(threaded.io(), testing.allocator, &db, &deps);
    defer testing.allocator.free(missing);

    try testing.expectEqual(@as(usize, 2), missing.len);
    try testing.expectEqualStrings("beta", missing[0]);
    try testing.expectEqualStrings("gamma", missing[1]);
}

test "collectMissingDepNames returns empty when every dep is fully installed" {
    const path = try setupPrefix("missing_deps_all_present");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try seedInstalledKeg(&db, path, "alpha", "1.0", true);
    try seedInstalledKeg(&db, path, "beta", "1.0", true);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const deps = [_][]const u8{ "alpha", "beta" };
    const missing = try upgrade.collectMissingDepNames(threaded.io(), testing.allocator, &db, &deps);
    defer testing.allocator.free(missing);

    try testing.expectEqual(@as(usize, 0), missing.len);
}

// Pre-fix, `collectMissingDepNames` only consulted the DB. A dep whose
// `opt/<name>` link had been wiped (Cellar move, manual cleanup, broken
// install) was treated as installed and the upgrade walked past it -
// while `deps.resolve`'s strict probe would have queued a re-link from
// the install path. The asymmetry meant a tap upgrade against a
// nuked-opt dep would silently leave the link dead. Coupling the
// upgrade probe to `deps.isInstalled` brings parity, so the reinstall
// trigger fires under either entry point.
test "collectMissingDepNames flags a keg whose opt link has been nuked" {
    const path = try setupPrefix("missing_deps_opt_link_nuked");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try seedInstalledKeg(&db, path, "alpha", "1.0", false); // cellar yes, opt link no

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const deps = [_][]const u8{"alpha"};
    const missing = try upgrade.collectMissingDepNames(threaded.io(), testing.allocator, &db, &deps);
    defer testing.allocator.free(missing);

    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqualStrings("alpha", missing[0]);
}

test "upgrade <pinned-tap-keg> short-circuits without resolving HEAD" {
    const path = try setupPrefix("upgrade_tap_pinned");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, tap, store_sha256, cellar_path, pinned)
            \\VALUES ('frozen-tap', 'user/repo/frozen-tap', '1.0', 'user/repo', 'sha', '/cellar/frozen-tap/1.0', 1);
        );
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    // Pinned + non-force = quiet skip on the tap branch too.
    try upgrade.execute(&ctx, testing.allocator, &.{"frozen-tap"});
}

// `backfillCaskTap` is the lazy-attribution writer the v5-row fallback
// probe relies on: once it discovers the owning tap, subsequent
// upgrades must pre-route directly instead of probing every registered
// tap again. The pure SQL check sidesteps the network surface and pins
// both the success and the WHERE-tap-IS-NULL idempotence guard.
fn readCaskTap(db: *sqlite.Database, token: []const u8) !?[]u8 {
    var stmt = try db.prepare("SELECT tap FROM casks WHERE token = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindText(1, token);
    _ = try stmt.step();
    const raw = stmt.columnText(0) orelse return null;
    const slice = std.mem.sliceTo(raw, 0);
    return try testing.allocator.dupe(u8, slice);
}

test "backfillCaskTap writes the tap label on a NULL row" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO casks(token, name, version, url)
        \\VALUES ('legacy', 'legacy', '1.0', 'https://example.invalid/x.dmg');
    );

    upgrade.backfillCaskTap(&db, "legacy", "xykong/tap");

    const got = try readCaskTap(&db, "legacy") orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("xykong/tap", got);
}

test "backfillCaskTap leaves an already-set row alone (WHERE tap IS NULL)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO casks(token, name, version, url, tap)
        \\VALUES ('claimed', 'claimed', '1.0', 'https://example.invalid/x.dmg',
        \\        'first-owner/tap');
    );

    // Try to overwrite — the guard must keep the row's original tap.
    upgrade.backfillCaskTap(&db, "claimed", "different-owner/tap");

    const got = try readCaskTap(&db, "claimed") orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("first-owner/tap", got);
}

test "backfillCaskTap on an absent token is a silent no-op" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // No INSERT — the UPDATE matches zero rows, must not raise.
    upgrade.backfillCaskTap(&db, "never-installed", "x/y");

    var stmt = try db.prepare("SELECT COUNT(*) FROM casks;");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}
