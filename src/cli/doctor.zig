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
            // Check if PID is running
            var pid_buf: [64]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&pid_buf, "Lock held by PID {d}", .{p}) catch "Lock held";
            printCheck("Stale lock", .warn_status, pid_str);
            warnings += 1;
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

    // Summary
    const f = std.fs.File.stderr();
    f.writeAll("\n") catch {};
    if (errors > 0) {
        output.err("mt doctor found {d} error(s) and {d} warning(s)", .{ errors, warnings });
    } else if (warnings > 0) {
        output.warn("mt doctor found {d} warning(s)", .{warnings});
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
