//! malt — upgrade command
//! Upgrade installed packages and casks.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const lock_mod = @import("../db/lock.zig");
const client_mod = @import("../net/client.zig");
const api_mod = @import("../net/api.zig");
const cask_mod = @import("../core/cask.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "upgrade")) return;

    var cask_only = false;
    var pkg_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else if (std.mem.eql(u8, arg, "--cask")) {
            cask_only = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (pkg_name == null) pkg_name = arg;
        }
    }

    if (!cask_only and pkg_name == null) {
        output.warn("upgrade not yet implemented for formulas", .{});
        // Fall through to try cask upgrade if applicable
    }

    // Open DB + API for cask upgrade
    const prefix = atomic.maltPrefix();

    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk = lock_mod.LockFile.acquire(lock_path, 5000) catch {
        output.err("Could not acquire lock. Another malt process may be running.", .{});
        return;
    };
    defer lk.release();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    var cache_dir_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_dir_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    if (pkg_name) |name| {
        // Upgrade a specific cask
        upgradeCask(allocator, name, &db, &api, prefix);
    } else if (cask_only) {
        // Upgrade all outdated casks
        upgradeAllCasks(allocator, &db, &api, prefix);
    }
}

fn upgradeCask(allocator: std.mem.Allocator, token: []const u8, db: *sqlite.Database, api: *api_mod.BrewApi, prefix: [:0]const u8) void {
    const installed = cask_mod.lookupInstalled(db, token) orelse {
        output.err("{s} is not installed as a cask", .{token});
        return;
    };

    // Fetch latest version
    const cask_json = api.fetchCask(token) catch {
        output.err("Could not fetch cask info for {s}", .{token});
        return;
    };
    defer allocator.free(cask_json);

    var parsed_cask = cask_mod.parseCask(allocator, cask_json) catch {
        output.err("Failed to parse cask JSON for {s}", .{token});
        return;
    };
    defer parsed_cask.deinit();

    const installed_version = installed.version();
    if (std.mem.eql(u8, installed_version, parsed_cask.version)) {
        output.info("{s} is already at latest version {s}", .{ token, parsed_cask.version });
        return;
    }

    output.info("Upgrading {s} {s} -> {s}...", .{ token, installed_version, parsed_cask.version });

    // Uninstall old version
    var installer = cask_mod.CaskInstaller.init(allocator, db, prefix);
    installer.uninstall(token) catch {
        output.err("Failed to remove old version of {s}", .{token});
        return;
    };

    // Install new version
    const app_path = installer.install(&parsed_cask) catch {
        output.err("Failed to install new version of {s}", .{token});
        return;
    };

    cask_mod.recordInstall(db, &parsed_cask, app_path) catch {
        output.warn("Failed to record cask {s} in database", .{token});
    };
    allocator.free(app_path);

    output.success("{s} upgraded to {s}", .{ token, parsed_cask.version });
}

fn upgradeAllCasks(allocator: std.mem.Allocator, db: *sqlite.Database, api: *api_mod.BrewApi, prefix: [:0]const u8) void {
    var stmt = db.prepare("SELECT token, version FROM casks ORDER BY token;") catch return;
    defer stmt.finalize();

    var upgraded: u32 = 0;
    while (stmt.step() catch false) {
        const token_ptr = stmt.columnText(0) orelse continue;
        const token = std.mem.sliceTo(token_ptr, 0);

        // Skip auto-updating casks (they update themselves)
        upgradeCask(allocator, token, db, api, prefix);
        upgraded += 1;
    }

    if (upgraded == 0) {
        output.info("All casks are up to date.", .{});
    }
}
