//! malt — doctor command
//! System health check.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const store_mod = @import("../core/store.zig");
const lock_mod = @import("../db/lock.zig");
const atomic = @import("../fs/atomic.zig");
const clonefile = @import("../fs/clonefile.zig");
const output = @import("../ui/output.zig");
const color = @import("../ui/color.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "doctor")) return;

    const prefix = atomic.maltPrefix();
    var warnings: u32 = 0;
    var errors: u32 = 0;

    // 1. SQLite integrity
    blk: {
        var db_path_buf: [512]u8 = undefined;
        const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch break :blk;
        var db = sqlite.Database.open(db_path) catch {
            printCheck("SQLite integrity", .err_status, "Cannot open database");
            errors += 1;
            break :blk;
        };
        defer db.close();

        schema.initSchema(&db) catch {};

        var stmt = db.prepare("PRAGMA integrity_check;") catch {
            printCheck("SQLite integrity", .err_status, "Cannot run integrity check");
            errors += 1;
            break :blk;
        };
        defer stmt.finalize();

        if (stmt.step() catch false) {
            const result = stmt.columnText(0);
            if (result) |r| {
                const txt = std.mem.sliceTo(r, 0);
                if (std.mem.eql(u8, txt, "ok")) {
                    printCheck("SQLite integrity", .ok, null);
                } else {
                    printCheck("SQLite integrity", .err_status, "Database may be corrupt");
                    errors += 1;
                }
            }
        }
    }

    // 2. Check required directories exist
    const dirs = [_][]const u8{ "store", "Cellar", "Caskroom", "opt", "bin", "lib", "tmp", "cache", "db" };
    for (dirs) |dir| {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ prefix, dir }) catch continue;
        std.fs.accessAbsolute(p, .{}) catch {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Missing directory: {s}", .{p}) catch continue;
            printCheck("Directory structure", .warn_status, msg);
            warnings += 1;
            continue;
        };
    }
    printCheck("Directory structure", .ok, null);

    // 3. Stale lock
    blk2: {
        var lock_buf: [512]u8 = undefined;
        const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix}) catch break :blk2;
        const pid = lock_mod.LockFile.holderPid(lock_path);
        if (pid) |p| {
            // Check if PID is still running via kill(pid, 0)
            const is_alive = blk_alive: {
                std.posix.kill(p, 0) catch break :blk_alive false;
                break :blk_alive true;
            };
            if (is_alive) {
                var pid_buf: [128]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, "Lock held by active PID {d}", .{p}) catch "Lock held";
                printCheck("Stale lock", .warn_status, pid_str);
                warnings += 1;
            } else {
                var pid_buf: [128]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, "Stale lock from dead PID {d}. Run: rm {s}", .{ p, lock_path }) catch "Stale lock detected";
                printCheck("Stale lock", .warn_status, pid_str);
                warnings += 1;
            }
        } else {
            printCheck("Stale lock", .ok, null);
        }
    }

    // 4. APFS volume
    if (clonefile.isApfs(prefix)) {
        printCheck("APFS volume", .ok, null);
    } else {
        printCheck("APFS volume", .warn_status, "Not on APFS — clonefile unavailable");
        warnings += 1;
    }

    // 5. API reachable
    blk3: {
        var http = @import("../net/client.zig").HttpClient.init(allocator);
        defer http.deinit();
        const status = http.head("https://formulae.brew.sh") catch {
            printCheck("API reachable", .warn_status, "Cannot reach formulae.brew.sh");
            warnings += 1;
            break :blk3;
        };
        if (status >= 200 and status < 400) {
            printCheck("API reachable", .ok, null);
        } else {
            printCheck("API reachable", .warn_status, "API returned error status");
            warnings += 1;
        }
    }

    // 6. Orphaned store entries — directories in store/ with no DB reference
    blk6: {
        var db_path_buf2: [512]u8 = undefined;
        const db_path2 = std.fmt.bufPrint(&db_path_buf2, "{s}/db/malt.db", .{prefix}) catch break :blk6;
        var db2 = sqlite.Database.open(db_path2) catch break :blk6;
        defer db2.close();

        var store_path_buf: [512]u8 = undefined;
        const store_path = std.fmt.bufPrint(&store_path_buf, "{s}/store", .{prefix}) catch break :blk6;
        var store_dir = std.fs.openDirAbsolute(store_path, .{ .iterate = true }) catch {
            // store/ doesn't exist or can't be read — not an error, just skip
            printCheck("Orphaned store entries", .ok, null);
            break :blk6;
        };
        defer store_dir.close();

        var orphan_count: u32 = 0;
        var iter = store_dir.iterate();
        while (iter.next() catch null) |entry| {
            // Each entry in store/ is a sha256 directory; check if it exists in store_refs
            var stmt = db2.prepare(
                "SELECT refcount FROM store_refs WHERE store_sha256 = ?1;",
            ) catch continue;
            defer stmt.finalize();
            stmt.bindText(1, entry.name) catch continue;
            const has_row = stmt.step() catch false;
            if (has_row) {
                const refcount = stmt.columnInt(0);
                if (refcount <= 0) orphan_count += 1;
            } else {
                // Not in DB at all — orphaned
                orphan_count += 1;
            }
        }

        if (orphan_count > 0) {
            var msg_buf2: [256]u8 = undefined;
            const msg2 = std.fmt.bufPrint(&msg_buf2, "{d} orphaned store entry(s). Run: mt gc", .{orphan_count}) catch "Orphaned store entries found. Run: mt gc";
            printCheck("Orphaned store entries", .warn_status, msg2);
            warnings += 1;
        } else {
            printCheck("Orphaned store entries", .ok, null);
        }
    }

    // 7. Missing kegs — DB keg entries whose Cellar path doesn't exist on disk
    blk7: {
        var db_path_buf3: [512]u8 = undefined;
        const db_path3 = std.fmt.bufPrint(&db_path_buf3, "{s}/db/malt.db", .{prefix}) catch break :blk7;
        var db3 = sqlite.Database.open(db_path3) catch break :blk7;
        defer db3.close();

        var stmt = db3.prepare("SELECT name, version, cellar_path FROM kegs;") catch break :blk7;
        defer stmt.finalize();

        var missing_count: u32 = 0;
        while (stmt.step() catch false) {
            const cellar_raw = stmt.columnText(2) orelse continue;
            const cellar_path = std.mem.sliceTo(cellar_raw, 0);
            std.fs.accessAbsolute(cellar_path, .{}) catch {
                missing_count += 1;
            };
        }

        if (missing_count > 0) {
            var msg_buf3: [256]u8 = undefined;
            const msg3 = std.fmt.bufPrint(&msg_buf3, "{d} keg(s) in DB but missing on disk. Reinstall affected packages", .{missing_count}) catch "Missing keg directories detected. Reinstall affected packages";
            printCheck("Missing kegs", .err_status, msg3);
            errors += 1;
        } else {
            printCheck("Missing kegs", .ok, null);
        }
    }

    // 8. Broken symlinks — walk bin/, lib/, include/, share/, sbin/ under prefix
    {
        const link_dirs = [_][]const u8{ "bin", "lib", "include", "share", "sbin" };
        var broken_count: u32 = 0;

        for (link_dirs) |subdir| {
            var dir_buf: [512]u8 = undefined;
            const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ prefix, subdir }) catch continue;
            var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();

            var dir_iter = dir.iterate();
            while (dir_iter.next() catch null) |entry| {
                if (entry.kind == .sym_link) {
                    // Try to stat the symlink target
                    _ = dir.statFile(entry.name) catch {
                        broken_count += 1;
                        continue;
                    };
                }
            }
        }

        if (broken_count > 0) {
            var msg_buf4: [256]u8 = undefined;
            const msg4 = std.fmt.bufPrint(&msg_buf4, "{d} broken symlink(s). Run: mt cleanup", .{broken_count}) catch "Broken symlinks found. Run: mt cleanup";
            printCheck("Broken symlinks", .warn_status, msg4);
            warnings += 1;
        } else {
            printCheck("Broken symlinks", .ok, null);
        }
    }

    // 9. Disk space — warn if < 1 GB free on the malt prefix volume
    blk9: {
        const mount_c = @cImport(@cInclude("sys/mount.h"));
        const posix_path = std.posix.toPosixPath(prefix) catch break :blk9;
        var stat_buf: mount_c.struct_statfs = undefined;
        const rc = mount_c.statfs(&posix_path, &stat_buf);
        if (rc != 0) {
            printCheck("Disk space", .warn_status, "Cannot determine free disk space");
            warnings += 1;
            break :blk9;
        }

        const free_bytes: u64 = @as(u64, @intCast(stat_buf.f_bavail)) * @as(u64, @intCast(stat_buf.f_bsize));
        const one_gb: u64 = 1024 * 1024 * 1024;
        if (free_bytes < one_gb) {
            const free_mb = free_bytes / (1024 * 1024);
            var msg_buf5: [256]u8 = undefined;
            const msg5 = std.fmt.bufPrint(&msg_buf5, "Only {d} MB free (< 1 GB). Free up disk space", .{free_mb}) catch "Low disk space (< 1 GB free)";
            printCheck("Disk space", .warn_status, msg5);
            warnings += 1;
        } else {
            printCheck("Disk space", .ok, null);
        }
    }

    // Summary + exit code
    const f = std.fs.File.stderr();
    f.writeAll("\n") catch {};
    if (errors > 0) {
        output.err("mt doctor found {d} error(s) and {d} warning(s)", .{ errors, warnings });
        std.process.exit(2);
    } else if (warnings > 0) {
        output.warn("mt doctor found {d} warning(s)", .{warnings});
        std.process.exit(1);
    } else {
        output.info("Your malt installation is healthy", .{});
    }
}

const CheckStatus = enum { ok, warn_status, err_status };

fn printCheck(name: []const u8, status: CheckStatus, detail: ?[]const u8) void {
    const f = std.fs.File.stderr();
    switch (status) {
        .ok => {
            if (color.isColorEnabled()) {
                f.writeAll(color.Style.green.code()) catch {};
                f.writeAll("[OK]    ") catch {};
                f.writeAll(color.Style.reset.code()) catch {};
            } else {
                f.writeAll("[OK]    ") catch {};
            }
        },
        .warn_status => {
            if (color.isColorEnabled()) {
                f.writeAll(color.Style.yellow.code()) catch {};
                f.writeAll("[WARN]  ") catch {};
                f.writeAll(color.Style.reset.code()) catch {};
            } else {
                f.writeAll("[WARN]  ") catch {};
            }
        },
        .err_status => {
            if (color.isColorEnabled()) {
                f.writeAll(color.Style.red.code()) catch {};
                f.writeAll("[ERROR] ") catch {};
                f.writeAll(color.Style.reset.code()) catch {};
            } else {
                f.writeAll("[ERROR] ") catch {};
            }
        },
    }
    f.writeAll(name) catch {};
    if (detail) |d| {
        f.writeAll(" — ") catch {};
        f.writeAll(d) catch {};
    }
    f.writeAll("\n") catch {};
}
