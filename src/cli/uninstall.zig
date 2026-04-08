//! malt — uninstall command
//! Remove installed packages.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const lock_mod = @import("../db/lock.zig");
const linker = @import("../core/linker.zig");
const cellar = @import("../core/cellar.zig");
const store = @import("../core/store.zig");
const cask_mod = @import("../core/cask.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "uninstall")) return;

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
        return;
    };

    const prefix = atomic.maltPrefix();

    // Acquire lock
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lock = lock_mod.LockFile.acquire(lock_path, 5000) catch {
        output.err("Could not acquire lock. Another malt process may be running.", .{});
        return;
    };
    defer lock.release();

    // Open DB
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    // Check if it's a cask first (or if --cask was passed)
    if (force_cask or cask_mod.isInstalled(&db, name)) {
        uninstallCask(allocator, name, &db, prefix, force);
        return;
    }

    // Find the keg
    var find_stmt = db.prepare(
        "SELECT id, version, store_sha256 FROM kegs WHERE name = ?1 LIMIT 1;",
    ) catch return;
    defer find_stmt.finalize();
    find_stmt.bindText(1, name) catch return;

    const found = find_stmt.step() catch false;
    if (!found) {
        output.err("{s} is not installed", .{name});
        return;
    }

    const keg_id = find_stmt.columnInt(0);
    const ver_ptr = find_stmt.columnText(1);
    const sha_ptr = find_stmt.columnText(2);
    const version = if (ver_ptr) |v| std.mem.sliceTo(v, 0) else "unknown";
    const sha256 = if (sha_ptr) |s| std.mem.sliceTo(s, 0) else "";

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
            return;
        }
    }

    output.info("Uninstalling {s} {s}...", .{ name, version });

    // Unlink symlinks
    var lnk = linker.Linker.init(allocator, &db, prefix);
    lnk.unlink(keg_id) catch {
        output.warn("Could not remove all symlinks for {s}", .{name});
    };

    // Remove Cellar directory
    cellar.remove(prefix, name, version) catch {
        output.warn("Could not remove cellar entry for {s} {s}", .{ name, version });
    };
    // Also remove parent if empty (e.g. Cellar/jq/ after removing Cellar/jq/1.8.1/)
    {
        var parent_buf: [512]u8 = undefined;
        const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch "";
        if (parent_path.len > 0) std.fs.deleteDirAbsolute(parent_path) catch {}; // intentional: only succeeds if empty
    }
    // Remove opt/ symlink
    {
        var opt_buf: [512]u8 = undefined;
        const opt_path = std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{ prefix, name }) catch "";
        if (opt_path.len > 0) std.fs.cwd().deleteFile(opt_path) catch {}; // intentional: may not exist
    }

    // Decrement store ref
    if (sha256.len > 0) {
        var st = store.Store.init(allocator, &db, prefix);
        st.decrementRef(sha256) catch {
            output.warn("Could not decrement store ref for {s}", .{name});
        };
    }

    // Delete from DB (CASCADE handles deps/links)
    var del_stmt = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch return;
    defer del_stmt.finalize();
    del_stmt.bindInt(1, keg_id) catch return;
    _ = del_stmt.step() catch {
        output.warn("Could not delete DB record for {s}", .{name});
    };

    output.success("{s} uninstalled", .{name});
}

/// Uninstall a cask by token.
fn uninstallCask(allocator: std.mem.Allocator, token: []const u8, db: *sqlite.Database, prefix: [:0]const u8, force: bool) void {
    const info = cask_mod.lookupInstalled(db, token) orelse {
        output.err("{s} is not installed as a cask", .{token});
        return;
    };

    // Check if running (unless --force)
    if (!force) {
        if (info.appPath()) |app_path| {
            if (cask_mod.CaskInstaller.isAppRunningPub(app_path)) {
                output.err("{s} appears to be running. Quit the app first, or use --force.", .{token});
                return;
            }
        }
    }

    output.info("Uninstalling cask {s}...", .{token});

    var installer = cask_mod.CaskInstaller.init(allocator, db, prefix);
    installer.uninstall(token) catch {
        output.err("Failed to uninstall cask {s}", .{token});
        return;
    };

    output.success("{s} uninstalled", .{token});
}
