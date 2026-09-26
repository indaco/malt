//! malt — uninstall command
//! Remove installed packages.

const std = @import("std");
const app_ctx = @import("../app_ctx.zig");
const AppCtx = app_ctx.AppCtx;
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
const signals = @import("../core/signals.zig");

/// One resolved name; `keg` is null for a cask.
const Target = struct {
    name: []const u8,
    keg: ?Keg,
};

const Keg = struct {
    id: i64,
    /// Owned: the row's text dies with its statement.
    version: []const u8,
    revision: i64,
};

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "uninstall")) return;

    // Global flag: `main` strips `--dry-run` from argv before we see it.
    const dry_run = output.isDryRun();
    var force = false;
    var force_cask = false;
    // Tokens borrow from `args`, which outlives this call, so no dup is needed.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);

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
            // A repeat would fail its second lookup as "not installed".
            if (!containsName(names.items, arg)) try names.append(allocator, arg);
        }
    }

    if (names.items.len == 0) {
        output.err("Usage: mt uninstall <package>...", .{});
        return error.Aborted;
    }

    const prefix = atomic.maltPrefixOrAbort();

    // Acquire lock
    var lock_path_buf: [prefix_path.path_buf_len]u8 = undefined;
    const lock_path = prefix_path.join(&lock_path_buf, prefix, "/db/malt.lock") catch {
        output.err("lock path too long", .{});
        return error.Aborted;
    };
    var lock = lock_mod.LockFile.acquire(ctx.io, lock_path, 5000) catch |e| switch (e) {
        // Fresh prefix with no `db/` dir → nothing is installed, so the
        // requested packages certainly aren't. Say so plainly instead of
        // reporting phantom lock contention.
        error.DirMissing => {
            for (names.items) |name| output.err("{s} is not installed", .{name});
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

    // Resolve every name before removing any, so an unknown one or a running
    // app aborts the batch with nothing touched. A cask wins over a formula
    // of the same name.
    var targets: std.ArrayList(Target) = .empty;
    defer {
        for (targets.items) |t| if (t.keg) |k| allocator.free(k.version);
        targets.deinit(allocator);
    }
    try targets.ensureTotalCapacityPrecise(allocator, names.items.len);
    var refused = false;
    for (names.items) |name| {
        if (cask_mod.lookupInstalled(&db, name)) |info| {
            refuseIfRunning(ctx.io, name, &info) catch {
                refused = true;
                continue;
            };
            targets.appendAssumeCapacity(.{ .name = name, .keg = null });
        } else if (force_cask) {
            output.err("{s} is not installed as a cask", .{name});
            refused = true;
        } else if (try lookupKeg(&db, allocator, name)) |keg| {
            targets.appendAssumeCapacity(.{ .name = name, .keg = keg });
        } else {
            output.err("{s} is not installed", .{name});
            refused = true;
        }
    }
    if (refused) return error.Aborted;

    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(allocator);
    for (targets.items, 0..) |t, i| {
        if (t.keg != null) try gateDependents(&db, allocator, targets.items, i, force, &edges);
    }
    const order = try removalOrder(allocator, targets.items.len, edges.items);
    defer allocator.free(order);

    // Resolved before any removal: a malformed MALT_CACHE exits the process,
    // and the preview must fail it the same way.
    const cache_dir: ?[]const u8 = for (targets.items) |t| {
        if (t.keg == null) break atomic.maltCacheDir(allocator) catch {
            output.err("Failed to resolve cache directory", .{});
            return error.Aborted;
        };
    } else null;
    defer if (cache_dir) |d| allocator.free(d);

    for (order, 0..) |ti, pos| {
        if (signals.isInterrupted()) {
            reportSkipped(targets.items, order[pos..]);
            return error.UserInterrupted;
        }
        const t = targets.items[ti];
        const removed = if (t.keg) |keg|
            removeFormula(ctx, allocator, &db, prefix, t.name, keg, dry_run)
        else
            uninstallCask(ctx, allocator, t.name, &db, prefix, cache_dir.?, force, dry_run);
        removed catch |e| {
            // The next removal would most likely hit the same failure.
            reportSkipped(targets.items, order[pos + 1 ..]);
            return e;
        };
    }
}

fn reportSkipped(batch: []const Target, rest: []const usize) void {
    for (rest) |ti| output.err("{s} was not uninstalled", .{batch[ti].name});
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn lookupKeg(db: *sqlite.Database, allocator: std.mem.Allocator, name: []const u8) error{ Aborted, OutOfMemory }!?Keg {
    var stmt = db.prepare(
        "SELECT id, version, revision FROM kegs WHERE name = ?1 LIMIT 1;",
    ) catch return readFailed(db);
    defer stmt.finalize();
    stmt.bindText(1, name) catch return readFailed(db);
    if (!(stmt.step() catch return readFailed(db))) return null;

    const version = if (stmt.columnText(1)) |v| std.mem.sliceTo(v, 0) else "unknown";
    return .{
        .id = stmt.columnInt(0),
        .version = try allocator.dupe(u8, version),
        .revision = stmt.columnInt(2),
    };
}

/// Target `dependent` depends on target `dep`, so it has to go first.
const Edge = struct { dep: usize, dependent: usize };

/// Records which batch targets depend on `batch[i]`, and refuses while a keg
/// outside the batch does. A check that cannot run refuses too, since
/// removing a keg others need is the harm it guards; `force` skips both
/// refusals and only loses the removal order.
fn gateDependents(
    db: *sqlite.Database,
    allocator: std.mem.Allocator,
    batch: []const Target,
    i: usize,
    force: bool,
    edges: *std.ArrayList(Edge),
) error{ Aborted, OutOfMemory }!void {
    const name = batch[i].name;
    var stmt = db.prepare(
        \\SELECT k.id, k.name FROM dependencies d
        \\JOIN kegs k ON k.id = d.keg_id
        \\WHERE d.dep_name = ?1;
    ) catch return unreadableUnlessForced(db, name, force);
    defer stmt.finalize();
    stmt.bindText(1, name) catch return unreadableUnlessForced(db, name, force);

    while (stmt.step() catch return unreadableUnlessForced(db, name, force)) {
        if (batchIndex(batch, stmt.columnInt(0))) |j| {
            try edges.append(allocator, .{ .dep = i, .dependent = j });
        } else if (!force) {
            const dependent = if (stmt.columnText(1)) |d| std.mem.sliceTo(d, 0) else "unknown";
            output.err("{s} is required by {s}. Use --force to remove anyway.", .{ name, dependent });
            return error.Aborted;
        }
    }
}

fn unreadableUnlessForced(db: *sqlite.Database, name: []const u8, force: bool) error{Aborted}!void {
    if (!force) return dependentsUnreadable(db, name);
}

// By row, not name: a name can own several installed versions, and the
// batch removes only the one it looked up.
fn batchIndex(batch: []const Target, keg_id: i64) ?usize {
    for (batch, 0..) |t, i| if (t.keg) |k| if (k.id == keg_id) return i;
    return null;
}

/// Batch indices with every dependent ahead of what it depends on, so a
/// failure partway never strands a dependent without its dependency. Ties
/// and cycles keep argv order.
fn removalOrder(allocator: std.mem.Allocator, n: usize, edges: []const Edge) error{OutOfMemory}![]usize {
    const order = try allocator.alloc(usize, n);
    errdefer allocator.free(order);
    const placed = try allocator.alloc(bool, n);
    defer allocator.free(placed);
    @memset(placed, false);

    for (order) |*slot| {
        var first: ?usize = null;
        const pick = for (0..n) |i| {
            if (placed[i]) continue;
            if (first == null) first = i;
            if (dependentsPlaced(edges, placed, i)) break i;
        } else first.?; // Only a cycle leaves nothing ready.
        placed[pick] = true;
        slot.* = pick;
    }
    return order;
}

fn dependentsPlaced(edges: []const Edge, placed: []const bool, i: usize) bool {
    for (edges) |e| if (e.dep == i and e.dependent != i and !placed[e.dependent]) return false;
    return true;
}

fn removeFormula(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    prefix: [:0]const u8,
    name: []const u8,
    keg: Keg,
    dry_run: bool,
) error{Aborted}!void {
    const version = keg.version;
    if (dry_run) {
        output.info("Dry run: would uninstall {s} {s}", .{ name, version });
        return;
    }

    // Revision-aware dir name for the on-disk cellar entry.
    var pkgver_buf: [128]u8 = undefined;
    const pkg_version = formula_mod.pkgVersion(&pkgver_buf, version, keg.revision) catch version;

    output.info("Uninstalling {s} {s}...", .{ name, version });

    // Stop and unregister any associated launchd service before tearing down
    // files. The service name we register matches the formula name.
    services_mod.announceStop(ctx.io, allocator, db, name);
    supervisor_mod.stopAndUnregister(.{ .allocator = allocator, .io = ctx.io, .db = db }, name);

    // Unlink symlinks
    var lnk = linker.Linker.init(ctx.io, allocator, db, prefix);
    // Only a DB error surfaces here (filesystem misses are skipped inside).
    // Carrying on would CASCADE away the rows that track the surviving links.
    lnk.unlink(keg.id) catch {
        output.err("Could not remove the links for {s}: {s}", .{ name, db.errMsg() });
        return error.Aborted;
    };

    // Land the DB writes before any Cellar teardown so a SIGKILL
    // between filesystem and database steps can't leave a keg row
    // pointing at a Cellar dir that is gone. CASCADE drops deps/links rows.
    finalizeDbRemoval(db, keg.id, name) catch {
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
                if (!nameStillRecorded(db, name))
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

test "batchIndex matches the batch's own rows, not every row sharing a name" {
    const batch = [_]Target{
        // A cask removes no keg, even one with the same name.
        .{ .name = "foo", .keg = null },
        .{ .name = "foo", .keg = .{ .id = 1, .version = "1.0", .revision = 0 } },
    };
    try testing.expectEqual(@as(?usize, 1), batchIndex(&batch, 1));
    // Another installed version of foo stays behind.
    try testing.expectEqual(@as(?usize, null), batchIndex(&batch, 2));
    try testing.expectEqual(@as(?usize, null), batchIndex(&.{}, 1));
}

fn expectOrder(expected: []const usize, n: usize, edges: []const Edge) !void {
    const order = try removalOrder(testing.allocator, n, edges);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(usize, expected, order);
}

test "removalOrder puts every dependent ahead of its dependency and keeps argv order otherwise" {
    try expectOrder(&.{}, 0, &.{});
    try expectOrder(&.{ 0, 1, 2 }, 3, &.{});
    // 1 depends on 0.
    try expectOrder(&.{ 1, 0 }, 2, &.{.{ .dep = 0, .dependent = 1 }});
    // Chain 2 -> 1 -> 0, typed dependency-first.
    try expectOrder(&.{ 2, 1, 0 }, 3, &.{ .{ .dep = 0, .dependent = 1 }, .{ .dep = 1, .dependent = 2 } });
    // Both 1 and 2 need 0; the unrelated 3 keeps its place after them.
    try expectOrder(&.{ 1, 2, 0, 3 }, 4, &.{ .{ .dep = 0, .dependent = 1 }, .{ .dep = 0, .dependent = 2 } });
    // A self-edge can't block its own keg.
    try expectOrder(&.{ 0, 1 }, 2, &.{.{ .dep = 0, .dependent = 0 }});
}

test "removalOrder breaks a dependency cycle in argv order instead of stalling" {
    // The unrelated 2 is ready first; the cycle then falls back to argv order.
    try expectOrder(&.{ 2, 0, 1 }, 3, &.{ .{ .dep = 0, .dependent = 1 }, .{ .dep = 1, .dependent = 0 } });
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

/// `--force` overrides dependents, not a live app: the installer refuses to
/// remove one regardless, and by then the stored phases have already acted
/// on the version that is staying.
fn refuseIfRunning(io: std.Io, token: []const u8, info: *const cask_mod.InstalledCask) error{Aborted}!void {
    const app_path = info.appPath() orelse return;
    if (!cask_mod.CaskInstaller.isAppRunningPub(io, app_path)) return;
    output.err("{s} appears to be running. Quit the app first.", .{token});
    return error.Aborted;
}

/// Uninstall a cask by token.
fn uninstallCask(ctx: *const AppCtx, allocator: std.mem.Allocator, token: []const u8, db: *sqlite.Database, prefix: [:0]const u8, cache_dir: []const u8, force: bool, dry_run: bool) !void {
    const info = cask_mod.lookupInstalled(db, token) orelse {
        output.err("{s} is not installed as a cask", .{token});
        return error.Aborted;
    };

    // Stored flight steps are recorded side effects, not checks, so the
    // preview stops before them.
    if (dry_run) {
        output.info("Dry run: would uninstall cask {s} {s}", .{ token, info.version() });
        return;
    }

    // Again, right before the stored steps: an earlier removal in the batch
    // may have started it.
    try refuseIfRunning(ctx.io, token, &info);

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

test "uninstallCask refuses an app started after the batch checked it, before any stored step runs" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    // Never created: only the stand-in's argv carries it.
    const app_path = "/nonexistent/malt-uninstall-recheck/Recheck.app";
    const cask_json =
        \\{"token":"recheck","name":["Recheck"],"version":"1.0","desc":"","homepage":"",
        \\ "url":"https://example.invalid/recheck.dmg",
        \\ "sha256":"00000000000000000000000000000000000000000000000000000000deadbeef",
        \\ "auto_updates":false,"artifacts":[{"app":["Recheck.app"]}]}
    ;
    var parsed = try cask_mod.parseCask(testing.allocator, cask_json);
    defer parsed.deinit();
    try cask_mod.recordInstall(&db, &parsed, app_path, null);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = app_ctx.processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    // Stands in for the app: `pgrep -f` sees the path in argv, and cat
    // blocks on its open stdin until the kill.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/cat", "-", app_path },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    var tries: usize = 0;
    // Spawn to exec is async: poll every 10ms, for up to 3s.
    while (tries < 300 and !cask_mod.CaskInstaller.isAppRunningPub(io, app_path)) : (tries += 1)
        std.Io.sleep(io, .fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    try testing.expect(cask_mod.CaskInstaller.isAppRunningPub(io, app_path));

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    const ctx: AppCtx = .{ .io = io, .environ = .empty };
    // Aborted, not the installer's own AppRunning: that refusal only comes
    // after the stored uninstall steps have run.
    try testing.expectError(error.Aborted, uninstallCask(&ctx, testing.allocator, "recheck", &db, "/nonexistent/malt-uninstall-recheck/prefix", "/nonexistent/malt-uninstall-recheck/cache", false, false));
    try testing.expect(std.mem.indexOf(u8, captured.items, "recheck appears to be running") != null);
    try testing.expect(cask_mod.isInstalled(&db, "recheck"));
}
