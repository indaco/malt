//! malt — uninstall command
//! Remove installed packages.

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const schema_report = @import("schema_report.zig");
const atomic = @import("../fs/atomic.zig");
const prefix_path = @import("../fs/prefix_path.zig");
const symlink = @import("../fs/symlink.zig");
const output = @import("../ui/output.zig");
const services_mod = @import("services.zig");
const lock_mod = @import("../db/lock.zig");
const linker = @import("../core/linker.zig");
const cellar = @import("../core/cellar.zig");
const cask_mod = @import("../core/cask.zig");
const artefact_cache = @import("../core/artefact_cache.zig");
const formula_mod = @import("../core/formula.zig");
const supervisor_mod = @import("../core/services/supervisor.zig");
const help = @import("help.zig");
const lock_report = @import("lock_report.zig");
const snap_mod = @import("outdated/snapshot.zig");
const post_install = @import("install/post_install.zig");
const sink_mod = @import("install/sink.zig");

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "uninstall")) return;

    // Global flag: `main` strips `--dry-run` from argv before we see it.
    const dry_run = output.isDryRun();
    var force = false;
    var force_cask = false;
    var pkg_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--cask")) {
            force_cask = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else if (arg.len > 0 and arg[0] == '-') {
            // Refused, not skipped: a mistyped preview would remove for real.
            output.err("Unknown flag: {s}", .{arg});
            return error.Aborted;
        } else if (arg.len > 0) {
            if (pkg_name == null) pkg_name = arg;
        }
    }

    const name = pkg_name orelse {
        output.err("Usage: mt uninstall <package>", .{});
        return error.Aborted;
    };

    const prefix = atomic.maltPrefixOrAbort();

    // Acquire lock
    var lock_path_buf: [prefix_path.path_buf_len]u8 = undefined;
    const lock_path = prefix_path.join(&lock_path_buf, prefix, "/db/malt.lock") catch {
        output.err("lock path too long", .{});
        return error.Aborted;
    };
    var lock = lock_mod.LockFile.acquire(ctx.io, lock_path, 5000) catch |e| switch (e) {
        // Fresh prefix with no `db/` dir → nothing is installed, so the
        // requested package certainly isn't. Say so plainly instead of
        // reporting phantom lock contention.
        error.DirMissing => {
            output.err("{s} is not installed", .{name});
            return error.Aborted;
        },
        else => {
            lock_report.reportAcquireFailure(e, prefix);
            return error.Aborted;
        },
    };
    defer lock.release(ctx.io);

    // Open DB
    var db_path_buf: [prefix_path.path_buf_len]u8 = undefined;
    const db_path = prefix_path.joinZ(&db_path_buf, prefix, "/db/malt.db") catch {
        output.err("database path too long", .{});
        return error.Aborted;
    };
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
    schema.initSchema(&db) catch |e| return schema_report.abortInitFailure(&db, e, prefix);

    // Check if it's a cask first (or if --cask was passed)
    if (force_cask or cask_mod.isInstalled(&db, name)) {
        try uninstallCask(ctx, allocator, name, &db, prefix, force, dry_run);
        return;
    }

    // Find the keg
    var find_stmt = db.prepare(
        "SELECT id, version, revision FROM kegs WHERE name = ?1 LIMIT 1;",
    ) catch return readFailed(&db);
    defer find_stmt.finalize();
    find_stmt.bindText(1, name) catch return readFailed(&db);

    const found = find_stmt.step() catch return readFailed(&db);
    if (!found) {
        output.err("{s} is not installed", .{name});
        return error.Aborted;
    }

    const keg_id = find_stmt.columnInt(0);
    const ver_ptr = find_stmt.columnText(1);
    const revision = find_stmt.columnInt(2);
    const version = if (ver_ptr) |v| std.mem.sliceTo(v, 0) else "unknown";

    // Revision-aware dir name for the on-disk cellar entry.
    var pkgver_buf: [128]u8 = undefined;
    const pkg_version = formula_mod.pkgVersion(&pkgver_buf, version, revision) catch version;

    // Check for dependents (unless --force). A check that cannot run
    // refuses, since removing a keg others need is the harm it guards.
    if (!force) {
        var dep_stmt = db.prepare(
            \\SELECT k.name FROM dependencies d
            \\JOIN kegs k ON k.id = d.keg_id
            \\WHERE d.dep_name = ?1;
        ) catch return dependentsUnreadable(&db, name);
        defer dep_stmt.finalize();
        dep_stmt.bindText(1, name) catch return dependentsUnreadable(&db, name);

        if (dep_stmt.step() catch return dependentsUnreadable(&db, name)) {
            const dependent = dep_stmt.columnText(0);
            const dep_name = if (dependent) |d| std.mem.sliceTo(d, 0) else "unknown";
            output.err("{s} is required by {s}. Use --force to remove anyway.", .{ name, dep_name });
            return error.Aborted;
        }
    }

    if (dry_run) {
        output.info("Dry run: would uninstall {s} {s}", .{ name, version });
        return;
    }

    output.info("Uninstalling {s} {s}...", .{ name, version });

    // Stop and unregister any associated launchd service before tearing down
    // files. The service name we register matches the formula name.
    services_mod.announceStop(ctx.io, allocator, &db, name);
    supervisor_mod.stopAndUnregister(.{ .allocator = allocator, .io = ctx.io, .db = &db }, name);

    // Unlink symlinks
    var lnk = linker.Linker.init(ctx.io, allocator, &db, prefix);
    // Only a DB error surfaces here (filesystem misses are skipped inside).
    // Carrying on would CASCADE away the rows that track the surviving links.
    lnk.unlink(keg_id) catch {
        output.err("Could not remove the links for {s}: {s}", .{ name, db.errMsg() });
        return error.Aborted;
    };

    // Land the DB writes before any Cellar teardown so a SIGKILL
    // between filesystem and database steps can't leave a keg row
    // pointing at a Cellar dir that is gone. CASCADE drops deps/links rows.
    finalizeDbRemoval(&db, keg_id, name) catch {
        output.warnAlways("{s} is still installed, but its links and any service were removed. Run `mt link {s}` to restore the links, or `mt uninstall {s}` to retry.", .{ name, name, name });
        return error.Aborted;
    };
    reconcileOutdated(ctx.io, allocator, .formulas, name);

    // Remove Cellar directory (dir name carries the _<revision> suffix
    // when the keg was installed with revision > 0).
    cellar.remove(ctx.io, prefix, name, pkg_version) catch |e| {
        output.warn("Could not remove cellar entry for {s} {s}: {s}", .{ name, version, cellar.describeError(e) });
    };
    // Also remove parent if empty (e.g. Cellar/jq/ after removing Cellar/jq/1.8.1/)
    {
        var parent_buf: [512]u8 = undefined;
        const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch "";
        if (parent_path.len > 0) {
            if (symlink.isSymlinkOrUnreadable(ctx.io, parent_path)) {
                // A link is indivisible: unlinking it cuts off every version
                // behind it, so the DB has to stand in for the emptiness
                // check the directory branch gets for free.
                if (!nameStillRecorded(&db, name))
                    std.Io.Dir.cwd().deleteFile(ctx.io, parent_path) catch {};
            } else {
                std.Io.Dir.deleteDirAbsolute(ctx.io, parent_path) catch {}; // Only succeeds when empty; sibling versions keep the dir alive.
            }
        }
    }
    // Remove opt/ symlink
    {
        var opt_buf: [512]u8 = undefined;
        const opt_path = std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{ prefix, name }) catch "";
        if (opt_path.len > 0) std.Io.Dir.cwd().deleteFile(ctx.io, opt_path) catch {}; // opt/ link absent on never-linked kegs.
    }

    output.success("{s} uninstalled", .{name});
}

fn readFailed(db: *sqlite.Database) error{Aborted} {
    output.err("Could not read the package database: {s}", .{db.errMsg()});
    return error.Aborted;
}

fn dependentsUnreadable(db: *sqlite.Database, name: []const u8) error{Aborted} {
    output.err("Could not check what depends on {s}: {s}. Use --force to remove anyway.", .{ name, db.errMsg() });
    return error.Aborted;
}

/// Drop the removed package from `{cache}/outdated.json` so the TUI's raw
/// read stops painting it. Only after the row is gone: the file must never
/// run ahead of the DB. A MALT_CACHE the readers refuse is skipped, not
/// fatal — the uninstall has already committed.
fn reconcileOutdated(io: std.Io, allocator: std.mem.Allocator, table: snap_mod.Table, name: []const u8) void {
    const cache_dir = atomic.maltCacheDirChecked(allocator) catch return;
    defer allocator.free(cache_dir);
    snap_mod.reconcileEntry(io, allocator, cache_dir, table, name, .removed);
}

/// Whether any keg row for `name` survives this uninstall. Errors answer
/// "yes" so an unreadable DB can never be the reason a Cellar entry is torn
/// down.
fn nameStillRecorded(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT 1 FROM kegs WHERE name = ?1;") catch return true;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return true;
    return stmt.step() catch true;
}

// DB-side teardown for an uninstall. Deleting the keg row is what
// releases the store bytes: the `store_refs` row stays so the orphan
// sweep can find them. One transaction so CASCADE and the delete land
// together.
fn finalizeDbRemoval(db: *sqlite.Database, keg_id: i64, name: []const u8) sqlite.SqliteError!void {
    var began = false;
    errdefer {
        // Report first: ROLLBACK resets the connection's error message.
        output.err("Could not remove {s} from the database: {s}", .{ name, db.errMsg() });
        if (began) db.rollback();
    }
    try db.beginTransaction();
    began = true;

    var del = try db.prepare("DELETE FROM kegs WHERE id = ?1;");
    defer del.finalize();
    try del.bindInt(1, keg_id);
    _ = try del.step();

    try db.commit();
}

const testing = std.testing;

fn testSeedKeg(db: *sqlite.Database, name: []const u8, sha256: []const u8) !i64 {
    var ins = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES (?1, ?1, '1.0', 0, ?2, 'Cellar/x/1.0');
    );
    defer ins.finalize();
    try ins.bindText(1, name);
    try ins.bindText(2, sha256);
    _ = try ins.step();

    var sel = try db.prepare("SELECT id FROM kegs WHERE name = ?1;");
    defer sel.finalize();
    try sel.bindText(1, name);
    _ = try sel.step();
    return sel.columnInt(0);
}

fn testRefRowPresent(db: *sqlite.Database, sha256: []const u8) !bool {
    var sel = try db.prepare("SELECT 1 FROM store_refs WHERE store_sha256 = ?1;");
    defer sel.finalize();
    try sel.bindText(1, sha256);
    return try sel.step();
}

fn testKegPresent(db: *sqlite.Database, keg_id: i64) !bool {
    var sel = try db.prepare("SELECT 1 FROM kegs WHERE id = ?1;");
    defer sel.finalize();
    try sel.bindInt(1, keg_id);
    return try sel.step();
}

test "finalizeDbRemoval drops the kegs row and leaves the store claim for the orphan sweep" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const sha = "abc123";
    try db.exec("INSERT INTO store_refs (store_sha256) VALUES ('abc123');");
    const keg_id = try testSeedKeg(&db, "foo", sha);
    try finalizeDbRemoval(&db, keg_id, "foo");

    try testing.expect(!try testKegPresent(&db, keg_id));
    // The row is what makes the bytes visible to `purge --store-orphans`;
    // deleting it here would hide them from every reclaim path.
    try testing.expect(try testRefRowPresent(&db, sha));
}

test "finalizeDbRemoval leaves the kegs row when the delete is blocked" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const sha = "abc123";
    try db.exec("INSERT INTO store_refs (store_sha256) VALUES ('abc123');");
    const keg_id = try testSeedKeg(&db, "foo", sha);

    try db.exec(
        \\CREATE TRIGGER block_keg_delete BEFORE DELETE ON kegs
        \\BEGIN SELECT RAISE(ABORT, 'blocked'); END;
    );

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    try testing.expectError(sqlite.SqliteError.ConstraintViolation, finalizeDbRemoval(&db, keg_id, "foo"));
    // The rollback resets errMsg, so the cause must be printed before it.
    try testing.expect(std.mem.indexOf(u8, captured.items, "blocked") != null);

    try testing.expect(try testKegPresent(&db, keg_id));
    try testing.expect(try testRefRowPresent(&db, sha));
}

test "finalizeDbRemoval reports a failed BEGIN and leaves a transaction it does not own" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    const keg_id = try testSeedKeg(&db, "foo", "abc123");
    try db.exec("BEGIN;");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    try testing.expectError(sqlite.SqliteError.ExecFailed, finalizeDbRemoval(&db, keg_id, "foo"));
    try testing.expect(std.mem.indexOf(u8, captured.items, "within a transaction") != null);
    try testing.expect(db.inTransaction());
    try testing.expect(try testKegPresent(&db, keg_id));
}

/// Uninstall a cask by token.
fn uninstallCask(ctx: *const AppCtx, allocator: std.mem.Allocator, token: []const u8, db: *sqlite.Database, prefix: [:0]const u8, force: bool, dry_run: bool) !void {
    const info = cask_mod.lookupInstalled(db, token) orelse {
        output.err("{s} is not installed as a cask", .{token});
        return error.Aborted;
    };

    // `--force` overrides dependents, not a live app: the installer refuses
    // to remove one regardless, and by then the stored phases have already
    // acted on the version that is staying.
    if (info.appPath()) |app_path| {
        if (cask_mod.CaskInstaller.isAppRunningPub(ctx.io, app_path)) {
            output.err("{s} appears to be running. Quit the app first.", .{token});
            return error.Aborted;
        }
    }

    // Resolved before the preview: a malformed MALT_CACHE fails both runs alike.
    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to resolve cache directory", .{});
        return error.Aborted;
    };
    defer allocator.free(cache_dir);

    // Stored flight steps are recorded side effects, not checks, so the
    // preview stops before them.
    if (dry_run) {
        output.info("Dry run: would uninstall cask {s} {s}", .{ token, info.version() });
        return;
    }

    output.info("Uninstalling cask {s}...", .{token});
    artefact_cache.adoptLegacy(ctx.io, prefix, cache_dir);
    var installer = cask_mod.CaskInstaller.init(ctx.io, ctx.environ, allocator, db, prefix, cache_dir);

    // The steps the install stored, not today's API: they matched the
    // version on disk.
    var stored = post_install.storedFlight(db, allocator, token, sink_mod.terminal);
    defer if (stored) |*s| s.deinit();
    var flight = post_install.Flight.init(allocator);
    defer flight.deinit();
    installer.flight = flight.sink();
    // A failed preflight aborts before anything is removed, as on install.
    // The steps are frozen in the row, so without `--force` a preflight that
    // can never pass would keep the cask on disk for good.
    if (stored) |*s| if (!flight.runPhase(&installer, token, info.version(), s.get(.uninstall_preflight), .uninstall_preflight, sink_mod.terminal)) {
        if (!force) return error.Aborted;
        output.warn("--force: removing {s} although its uninstall preflight failed", .{token});
    };
    if (stored) |*s| flight.runUninstallMode(&installer, token, info.version(), s, sink_mod.terminal);

    installer.uninstall(token) catch |un_err| {
        if (un_err == error.AppRunning) {
            output.err("Cannot uninstall {s}: the app is running. Quit it and try again.", .{token});
            return error.AppRunning;
        }
        output.err(
            "Failed to uninstall cask {s}: {s} ({s})",
            .{ token, @errorName(un_err), db.errMsg() },
        );
        return error.Aborted;
    };
    reconcileOutdated(ctx.io, allocator, .casks, token);

    if (stored) |*s| _ = flight.runPhase(&installer, token, info.version(), s.get(.uninstall_postflight), .uninstall_postflight, sink_mod.terminal);

    output.success("{s} uninstalled", .{token});
}
