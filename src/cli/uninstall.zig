//! malt — uninstall command
//! Remove installed packages.

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const lock_mod = @import("../db/lock.zig");
const linker = @import("../core/linker.zig");
const cellar = @import("../core/cellar.zig");
const cask_mod = @import("../core/cask.zig");
const formula_mod = @import("../core/formula.zig");
const supervisor_mod = @import("../core/services/supervisor.zig");
const help = @import("help.zig");
const lock_report = @import("lock_report.zig");

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "uninstall")) return;

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
        } else if (arg.len > 0 and arg[0] != '-') {
            if (pkg_name == null) pkg_name = arg;
        }
    }

    const name = pkg_name orelse {
        output.err("Usage: mt uninstall <package>", .{});
        return error.Aborted;
    };

    const prefix = atomic.maltPrefixOrAbort();

    // Acquire lock
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
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
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    // Check if it's a cask first (or if --cask was passed)
    if (force_cask or cask_mod.isInstalled(&db, name)) {
        try uninstallCask(ctx, allocator, name, &db, prefix, force);
        return;
    }

    // Find the keg
    var find_stmt = db.prepare(
        "SELECT id, version, revision, store_sha256 FROM kegs WHERE name = ?1 LIMIT 1;",
    ) catch return;
    defer find_stmt.finalize();
    find_stmt.bindText(1, name) catch return;

    const found = find_stmt.step() catch false;
    if (!found) {
        output.err("{s} is not installed", .{name});
        return error.Aborted;
    }

    const keg_id = find_stmt.columnInt(0);
    const ver_ptr = find_stmt.columnText(1);
    const revision = find_stmt.columnInt(2);
    const sha_ptr = find_stmt.columnText(3);
    const version = if (ver_ptr) |v| std.mem.sliceTo(v, 0) else "unknown";
    const sha256 = if (sha_ptr) |s| std.mem.sliceTo(s, 0) else "";

    // Revision-aware dir name for the on-disk cellar entry.
    var pkgver_buf: [128]u8 = undefined;
    const pkg_version = formula_mod.pkgVersion(&pkgver_buf, version, revision) catch version;

    // Check for dependents (unless --force)
    if (!force) {
        var dep_stmt = db.prepare(
            \\SELECT k.name FROM dependencies d
            \\JOIN kegs k ON k.id = d.keg_id
            \\WHERE d.dep_name = ?1;
        ) catch return;
        defer dep_stmt.finalize();
        dep_stmt.bindText(1, name) catch return;

        if (dep_stmt.step() catch false) {
            const dependent = dep_stmt.columnText(0);
            const dep_name = if (dependent) |d| std.mem.sliceTo(d, 0) else "unknown";
            output.err("{s} is required by {s}. Use --force to remove anyway.", .{ name, dep_name });
            return error.Aborted;
        }
    }

    output.info("Uninstalling {s} {s}...", .{ name, version });

    // Stop and unregister any associated launchd service before tearing down
    // files. The service name we register matches the formula name.
    supervisor_mod.stopAndUnregister(.{ .allocator = allocator, .io = ctx.io, .db = &db }, name);

    // Unlink symlinks
    var lnk = linker.Linker.init(ctx.io, allocator, &db, prefix);
    lnk.unlink(keg_id) catch {
        output.warn("Could not remove all symlinks for {s}", .{name});
    };

    // Land the DB writes before any Cellar teardown so a SIGKILL
    // between filesystem and database steps can't strand a refcount
    // above the on-disk reality. CASCADE drops deps/links rows.
    finalizeDbRemoval(&db, sha256, keg_id) catch {
        output.warn("Could not finalize uninstall for {s}", .{name});
    };

    // Remove Cellar directory (dir name carries the _<revision> suffix
    // when the keg was installed with revision > 0).
    cellar.remove(ctx.io, prefix, name, pkg_version) catch {
        output.warn("Could not remove cellar entry for {s} {s}", .{ name, version });
    };
    // Also remove parent if empty (e.g. Cellar/jq/ after removing Cellar/jq/1.8.1/)
    {
        var parent_buf: [512]u8 = undefined;
        const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch "";
        if (parent_path.len > 0) std.Io.Dir.deleteDirAbsolute(ctx.io, parent_path) catch {}; // Only succeeds when empty; sibling versions keep the dir alive.
    }
    // Remove opt/ symlink
    {
        var opt_buf: [512]u8 = undefined;
        const opt_path = std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{ prefix, name }) catch "";
        if (opt_path.len > 0) std.Io.Dir.cwd().deleteFile(ctx.io, opt_path) catch {}; // opt/ link absent on never-linked kegs.
    }

    output.success("{s} uninstalled", .{name});
}

// Atomic DB-side teardown for an uninstall: the store-ref decrement and
// the kegs delete must commit together so a SIGKILL between them can't
// leave a refcount bumped above the on-disk Cellar reality.
fn finalizeDbRemoval(db: *sqlite.Database, sha256: []const u8, keg_id: i64) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    if (sha256.len > 0) {
        var dec = try db.prepare(
            "UPDATE store_refs SET refcount = refcount - 1 WHERE store_sha256 = ?1 AND refcount > 0;",
        );
        defer dec.finalize();
        try dec.bindText(1, sha256);
        _ = try dec.step();
    }

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

fn testRefcount(db: *sqlite.Database, sha256: []const u8) !?i64 {
    var sel = try db.prepare("SELECT refcount FROM store_refs WHERE store_sha256 = ?1;");
    defer sel.finalize();
    try sel.bindText(1, sha256);
    if (!try sel.step()) return null;
    return sel.columnInt(0);
}

fn testKegPresent(db: *sqlite.Database, keg_id: i64) !bool {
    var sel = try db.prepare("SELECT 1 FROM kegs WHERE id = ?1;");
    defer sel.finalize();
    try sel.bindInt(1, keg_id);
    return try sel.step();
}

test "finalizeDbRemoval bundles the ref decrement with the kegs delete" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const sha = "abc123";
    var ins_ref = try db.prepare("INSERT INTO store_refs (store_sha256, refcount) VALUES (?1, 2);");
    try ins_ref.bindText(1, sha);
    _ = try ins_ref.step();
    ins_ref.finalize();

    const keg_id = try testSeedKeg(&db, "foo", sha);
    try finalizeDbRemoval(&db, sha, keg_id);

    try testing.expect(!try testKegPresent(&db, keg_id));
    try testing.expectEqual(@as(?i64, 1), try testRefcount(&db, sha));
}

test "finalizeDbRemoval rolls the ref decrement back when the delete is blocked" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const sha = "abc123";
    var ins_ref = try db.prepare("INSERT INTO store_refs (store_sha256, refcount) VALUES (?1, 2);");
    try ins_ref.bindText(1, sha);
    _ = try ins_ref.step();
    ins_ref.finalize();

    const keg_id = try testSeedKeg(&db, "foo", sha);

    // Trip the DELETE so atomicity is observable: after the failure,
    // refcount must be untouched and the kegs row must still be there.
    try db.exec(
        \\CREATE TRIGGER block_keg_delete BEFORE DELETE ON kegs
        \\BEGIN SELECT RAISE(ABORT, 'blocked'); END;
    );

    try testing.expectError(sqlite.SqliteError.ConstraintViolation, finalizeDbRemoval(&db, sha, keg_id));

    try testing.expect(try testKegPresent(&db, keg_id));
    try testing.expectEqual(@as(?i64, 2), try testRefcount(&db, sha));
}

/// Uninstall a cask by token.
fn uninstallCask(ctx: *const AppCtx, allocator: std.mem.Allocator, token: []const u8, db: *sqlite.Database, prefix: [:0]const u8, force: bool) !void {
    const info = cask_mod.lookupInstalled(db, token) orelse {
        output.err("{s} is not installed as a cask", .{token});
        return error.Aborted;
    };

    // Check if running (unless --force)
    if (!force) {
        if (info.appPath()) |app_path| {
            if (cask_mod.CaskInstaller.isAppRunningPub(ctx.io, app_path)) {
                output.err("{s} appears to be running. Quit the app first, or use --force.", .{token});
                return error.Aborted;
            }
        }
    }

    output.info("Uninstalling cask {s}...", .{token});

    var installer = cask_mod.CaskInstaller.init(ctx.io, ctx.environ, allocator, db, prefix);
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

    output.success("{s} uninstalled", .{token});
}
