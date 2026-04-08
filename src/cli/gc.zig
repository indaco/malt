//! malt — gc command
//! Garbage collect unreferenced store entries.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const store_mod = @import("../core/store.zig");
const lock_mod = @import("../db/lock.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "gc")) return;

    var dry_run = false;
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

    // Acquire lock
    var lock_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk = lock_mod.LockFile.acquire(lock_path, 30000) catch {
        output.err("Another mt process is running", .{});
        return;
    };
    defer lk.release();

    var store = store_mod.Store.init(allocator, &db, prefix);
    var orphans_list = store.orphans() catch {
        output.err("Failed to find orphaned store entries", .{});
        return;
    };
    defer {
        for (orphans_list.items) |item| allocator.free(item);
        orphans_list.deinit(allocator);
    }

    if (orphans_list.items.len == 0) {
        output.info("No orphaned store entries found", .{});
        return;
    }

    if (dry_run) {
        output.info("Would remove {d} orphaned store entries:", .{orphans_list.items.len});
        for (orphans_list.items) |sha| {
            const f = std.fs.File.stderr();
            f.writeAll("  ") catch {};
            f.writeAll(sha) catch {};
            f.writeAll("\n") catch {};
        }
        return;
    }

    var removed: u32 = 0;
    for (orphans_list.items) |sha| {
        store.remove(sha) catch continue;
        removed += 1;
    }

    output.info("Freed {d} orphaned store entries", .{removed});
}
