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
const formula_mod = @import("../core/formula.zig");

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
        "SELECT id, version, revision, store_sha256 FROM kegs WHERE name = ?1 ORDER BY installed_at DESC LIMIT 1;",
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
    const current_revision = cur_stmt.columnInt(2);

    // pkg_version is what the on-disk Cellar / store dir is named after,
    // so the store-scan below must compare against this — not the bare
    // upstream `version` — to correctly skip a current revision-bumped
    // keg (e.g. version="1.9.2", revision=2 → label "1.9.2_2").
    var current_pkgver_buf: [128]u8 = undefined;
    const current_pkg_version = formula_mod.pkgVersion(&current_pkgver_buf, current_ver, current_revision) catch current_ver;

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
            // Compare against the on-disk pkg_version label so a
            // revision-bumped current keg is skipped correctly.
            if (std.mem.eql(u8, ver_entry.name, current_pkg_version)) continue;

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

    // target.version carries the on-disk pkg_version label (the store
    // dir name), so replaceKegRow can split it back into version +
    // revision and persist the rolled-back keg's true revision.
    const keg_id = replaceKegRow(
        &db,
        current_id,
        name,
        target.version,
        target.sha256,
        keg.path,
        old_pinned,
    ) catch return error.Aborted;

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

/// Swap the keg row identified by `old_keg_id` for a fresh row pointing
/// at `pkg_version` (the on-disk label, e.g. "1.9.2_2"). Splits the
/// label into `version` + `revision` so the new row reflects the
/// rolled-back keg's true revision instead of silently writing 0.
/// Returns the new keg row id. Caller owns the surrounding transaction.
pub fn replaceKegRow(
    db: *sqlite.Database,
    old_keg_id: i64,
    name: []const u8,
    pkg_version: []const u8,
    store_sha256: []const u8,
    cellar_path: []const u8,
    pinned: bool,
) !i64 {
    const parsed = formula_mod.parsePkgVersion(pkg_version);

    {
        var del = try db.prepare("DELETE FROM kegs WHERE id = ?1;");
        defer del.finalize();
        try del.bindInt(1, old_keg_id);
        _ = try del.step();
    }

    {
        var ins = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason, pinned)
            \\VALUES (?1, ?1, ?2, ?3, ?4, ?5, 'direct', ?6);
        );
        defer ins.finalize();
        try ins.bindText(1, name);
        try ins.bindText(2, parsed.version);
        try ins.bindInt(3, parsed.revision);
        try ins.bindText(4, store_sha256);
        try ins.bindText(5, cellar_path);
        try ins.bindInt(6, @intFromBool(pinned));
        _ = try ins.step();
    }

    var id_stmt = try db.prepare("SELECT last_insert_rowid();");
    defer id_stmt.finalize();
    if (!(try id_stmt.step())) return error.RecordFailed;
    return id_stmt.columnInt(0);
}

const testing = std.testing;

test "replaceKegRow splits pkg_version into version + revision" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // Current keg at revision=2; rollback target is revision=0 of same upstream version.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, pinned)
        \\VALUES ('libgit2', 'libgit2', '1.9.2', 2, 'sha-cur', '/c/libgit2/1.9.2_2', 1);
    );
    const old_id = blk: {
        var s = try db.prepare("SELECT id FROM kegs WHERE name='libgit2';");
        defer s.finalize();
        _ = try s.step();
        break :blk s.columnInt(0);
    };

    const new_id = try replaceKegRow(&db, old_id, "libgit2", "1.9.2", "sha-old", "/c/libgit2/1.9.2", true);

    var stmt = try db.prepare("SELECT version, revision, pinned FROM kegs WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_id);
    _ = try stmt.step();
    const ver = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("1.9.2", std.mem.sliceTo(ver, 0));
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(1));
    try testing.expect(stmt.columnBool(2));
}

test "replaceKegRow recovers a non-zero revision from pkg_version" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('python@3.14', 'python@3.14', '3.14.4', 1, 'sha-cur', '/c/python@3.14/3.14.4_1');
    );
    const old_id = blk: {
        var s = try db.prepare("SELECT id FROM kegs WHERE name='python@3.14';");
        defer s.finalize();
        _ = try s.step();
        break :blk s.columnInt(0);
    };

    // Rolling back to an earlier revision-2 build.
    const new_id = try replaceKegRow(&db, old_id, "python@3.14", "3.14.3_2", "sha-old", "/c/python@3.14/3.14.3_2", false);

    var stmt = try db.prepare("SELECT version, revision FROM kegs WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_id);
    _ = try stmt.step();
    const ver = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("3.14.3", std.mem.sliceTo(ver, 0));
    try testing.expectEqual(@as(i64, 2), stmt.columnInt(1));

    // Old row was deleted in the same swap.
    var cnt = try db.prepare("SELECT COUNT(*) FROM kegs WHERE name='python@3.14';");
    defer cnt.finalize();
    _ = try cnt.step();
    try testing.expectEqual(@as(i64, 1), cnt.columnInt(0));
}
