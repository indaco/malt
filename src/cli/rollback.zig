//! malt — rollback command
//! Revert a formula to its previous version using existing store entries.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const lock_mod = @import("../db/lock.zig");
const cellar = @import("../core/cellar.zig");
const linker_mod = @import("../core/linker.zig");
const store_mod = @import("../core/store.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

/// `error.Aborted` is returned on every user-facing failure. The caller has
/// already emitted a message via `output.err`; main.zig catches it and exits
/// non-zero without printing a stack trace.
pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "rollback")) return;

    if (args.len == 0) {
        output.err("Usage: mt rollback <package>", .{});
        return error.Aborted;
    }

    const name = args[0];
    var dry_run = output.isDryRun();
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) dry_run = true;
    }

    const prefix = atomic.maltPrefix();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return error.Aborted;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
    schema.initSchema(&db) catch return error.Aborted;

    // Find current installed version
    var cur_stmt = db.prepare(
        "SELECT id, version, store_sha256 FROM kegs WHERE name = ?1 ORDER BY installed_at DESC LIMIT 1;",
    ) catch return error.Aborted;
    defer cur_stmt.finalize();
    cur_stmt.bindText(1, name) catch return error.Aborted;

    if (!(cur_stmt.step() catch false)) {
        output.err("{s} is not installed", .{name});
        return error.Aborted;
    }

    const current_id = cur_stmt.columnInt(0);
    const current_ver_ptr = cur_stmt.columnText(1);
    const current_ver = if (current_ver_ptr) |v| std.mem.sliceTo(v, 0) else "unknown";

    // Look for other store entries that contain this formula
    // by scanning the store directory for entries that have {name}/ subdirectory
    var store_buf: [512]u8 = undefined;
    const store_dir_path = std.fmt.bufPrint(&store_buf, "{s}/store", .{prefix}) catch return error.Aborted;

    var store_dir = fs_compat.openDirAbsolute(store_dir_path, .{ .iterate = true }) catch {
        output.err("Cannot read store directory", .{});
        return error.Aborted;
    };
    defer store_dir.close();

    // Collect available versions from store entries
    const Entry = struct { sha256: []const u8, version: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

    var iter = store_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Check if this store entry contains {name}/ subdirectory
        var check_buf: [512]u8 = undefined;
        const check_path = std.fmt.bufPrint(&check_buf, "{s}/{s}/{s}", .{ store_dir_path, entry.name, name }) catch continue;

        var keg_dir = fs_compat.openDirAbsolute(check_path, .{ .iterate = true }) catch continue;
        defer keg_dir.close();

        // The first subdirectory is the version
        var keg_iter = keg_dir.iterate();
        while (keg_iter.next() catch null) |ver_entry| {
            if (ver_entry.kind != .directory) continue;
            // Skip current version
            if (std.mem.eql(u8, ver_entry.name, current_ver)) continue;

            const sha = allocator.dupe(u8, entry.name) catch continue;
            const ver = allocator.dupe(u8, ver_entry.name) catch continue;
            entries.append(allocator, .{ .sha256 = sha, .version = ver }) catch continue;
            break;
        }
    }

    if (entries.items.len == 0) {
        output.err("No previous version found for {s} in the store", .{name});
        output.info("The store only contains the current version ({s})", .{current_ver});
        return error.Aborted;
    }

    // Use the most recent previous version (last entry)
    const target = entries.items[entries.items.len - 1];

    output.info("Rolling back {s}: {s} -> {s}", .{ name, current_ver, target.version });

    if (dry_run) {
        output.info("Dry run: would rollback {s} from {s} to {s}", .{ name, current_ver, target.version });
        return;
    }

    // Acquire lock
    var lock_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix}) catch return error.Aborted;
    var lk = lock_mod.LockFile.acquire(lock_path, 30000) catch {
        output.err("Another mt process is running", .{});
        return error.Aborted;
    };
    defer lk.release();

    // Unlink current version
    var linker = linker_mod.Linker.init(allocator, &db, prefix);
    linker.unlink(current_id) catch {
        output.warn("Could not unlink current {s} — links may be stale", .{name});
    };

    // Remove current cellar entry
    cellar.remove(prefix, name, current_ver) catch {
        output.warn("Could not remove cellar entry for {s} {s}", .{ name, current_ver });
    };

    // Materialize the old version from store
    const keg = cellar.materialize(allocator, prefix, target.sha256, name, target.version) catch {
        output.err("Failed to materialize {s} {s} from store", .{ name, target.version });
        return error.Aborted;
    };

    // Update DB: delete old record, insert new one. Capture the old
    // pin BEFORE the delete so the new row can inherit it — rolling
    // back a held formula must not silently clear the user's hold.
    const old_pinned = capturePinnedById(&db, current_id);

    db.beginTransaction() catch return error.Aborted;
    errdefer db.rollback();

    {
        var del = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch return error.Aborted;
        defer del.finalize();
        del.bindInt(1, current_id) catch return error.Aborted;
        // Step failure inside the txn must trigger rollback, not a silent commit.
        _ = del.step() catch return error.Aborted;
    }

    {
        var ins = db.prepare(
            "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason, pinned)" ++
                " VALUES (?1, ?1, ?2, ?3, ?4, 'direct', ?5);",
        ) catch return error.Aborted;
        defer ins.finalize();
        ins.bindText(1, name) catch return error.Aborted;
        ins.bindText(2, target.version) catch return error.Aborted;
        ins.bindText(3, target.sha256) catch return error.Aborted;
        ins.bindText(4, keg.path) catch return error.Aborted;
        ins.bindInt(5, @intFromBool(old_pinned)) catch return error.Aborted;
        // Step failure inside the txn must trigger rollback, not a silent commit.
        _ = ins.step() catch return error.Aborted;
    }

    // Get new keg_id for linking
    var id_stmt = db.prepare("SELECT last_insert_rowid();") catch return error.Aborted;
    defer id_stmt.finalize();
    const keg_id = if (id_stmt.step() catch false) id_stmt.columnInt(0) else return error.Aborted;

    // Link the old version
    linker.link(keg.path, name, keg_id) catch {
        output.warn("Could not link restored {s} — try: mt link {s}", .{ name, name });
    };
    linker.linkOpt(name, target.version) catch {
        output.warn("Could not create opt link for {s}", .{name});
    };

    db.commit() catch return error.Aborted;

    output.info("{s} rolled back to {s}", .{ name, target.version });
}

/// Returns the `pinned` flag of the keg row identified by `keg_id`, or
/// false if the row is missing or the read fails. Pub for tests; used
/// inside `execute` to snapshot the hold across a DELETE/INSERT swap.
pub fn capturePinnedById(db: *sqlite.Database, keg_id: i64) bool {
    var stmt = db.prepare("SELECT pinned FROM kegs WHERE id = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return false;
    if (!(stmt.step() catch false)) return false;
    return stmt.columnBool(0);
}
