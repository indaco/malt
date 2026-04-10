//! malt — autoremove command
//! Remove orphaned dependencies.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const deps_mod = @import("../core/deps.zig");
const linker_mod = @import("../core/linker.zig");
const store_mod = @import("../core/store.zig");
const cellar_mod = @import("../core/cellar.zig");
const lock_mod = @import("../db/lock.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "autoremove")) return;

    var dry_run = output.isDryRun();
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) dry_run = true;
    }

    const prefix = atomic.maltPrefix();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    // Find orphans
    const orphans = deps_mod.findOrphans(allocator, &db) catch {
        output.err("Failed to find orphaned dependencies", .{});
        return;
    };
    defer {
        for (orphans) |o| allocator.free(o);
        allocator.free(orphans);
    }

    if (orphans.len == 0) {
        output.info("No orphaned dependencies found", .{});
        return;
    }

    if (dry_run) {
        output.info("Would remove {d} orphaned dependencies:", .{orphans.len});
        for (orphans) |name| {
            const f = std.fs.File.stderr();
            f.writeAll("  ") catch {};
            f.writeAll(name) catch {};
            f.writeAll("\n") catch {};
        }
        return;
    }

    // Acquire lock
    var lock_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk = lock_mod.LockFile.acquire(lock_path, 30000) catch {
        output.err("Another mt process is running", .{});
        return;
    };
    defer lk.release();

    var linker = linker_mod.Linker.init(allocator, &db, prefix);
    var store = store_mod.Store.init(allocator, &db, prefix);
    var removed: u32 = 0;

    for (orphans) |name| {
        // Find keg ID and details
        var stmt = db.prepare("SELECT id, version, store_sha256 FROM kegs WHERE name = ?1;") catch continue;
        defer stmt.finalize();
        stmt.bindText(1, name) catch continue;

        if (stmt.step() catch false) {
            const keg_id = stmt.columnInt(0);
            const version_ptr = stmt.columnText(1);
            const sha_ptr = stmt.columnText(2);

            // Unlink
            linker.unlink(keg_id) catch {};

            // Remove cellar
            if (version_ptr) |v| {
                cellar_mod.remove(prefix, name, std.mem.sliceTo(v, 0)) catch {};
            }
            // Remove empty parent dir
            {
                var parent_buf: [512]u8 = undefined;
                const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch "";
                if (parent_path.len > 0) std.fs.deleteDirAbsolute(parent_path) catch {};
            }

            // Decrement store ref
            if (sha_ptr) |s| {
                store.decrementRef(std.mem.sliceTo(s, 0)) catch {};
            }

            // Delete from DB (CASCADE handles deps/links)
            var del = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch continue;
            defer del.finalize();
            del.bindInt(1, keg_id) catch continue;
            _ = del.step() catch {};

            removed += 1;
        }
    }

    output.success("Removed {d} orphaned dependencies", .{removed});
}
