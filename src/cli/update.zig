//! malt — update command
//! Wipe the metadata cache (default) or refresh the outdated snapshot (`--check`).

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const atomic = @import("../fs/atomic.zig");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const outdated_mod = @import("outdated.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub const UpdateError = error{Aborted} || std.mem.Allocator.Error;

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) UpdateError!void {
    if (help.showIfRequested(args, "update")) return;

    var check_only = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        }
    }

    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to determine cache directory", .{});
        return error.Aborted;
    };
    defer allocator.free(cache_dir);

    if (check_only) {
        refreshSnapshot(allocator, cache_dir) catch |e| {
            output.err("Failed to refresh outdated snapshot: {s}", .{@errorName(e)});
            return error.Aborted;
        };
        output.info("Outdated snapshot refreshed.", .{});
        return;
    }

    // Stays sub-100ms: wipe API cache + invalidate snapshot; the next
    // `mt outdated` recomputes against the new world.
    var api_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&api_buf, "{s}/api", .{cache_dir})) |api_path| {
        fs_compat.deleteTreeAbsolute(api_path) catch {};
    } else |_| {}

    invalidateSnapshot(allocator, cache_dir);

    output.info("Cache cleared. Metadata will be re-fetched on next operation.", .{});
}

/// Best-effort: a leftover snapshot is harmless because the read path
/// filters through the live DB; worst case is one extra recompute.
fn invalidateSnapshot(allocator: std.mem.Allocator, cache_dir: []const u8) void {
    const path = outdated_mod.snapshotPath(allocator, cache_dir) catch return;
    defer allocator.free(path);
    fs_compat.deleteFileAbsolute(path) catch {};
}

fn refreshSnapshot(allocator: std.mem.Allocator, cache_dir: []const u8) !void {
    const prefix = atomic.maltPrefix();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return error.Aborted;
    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix: write an empty snapshot so readers get instant "all clear".
        try outdated_mod.writeSnapshot(allocator, cache_dir, .{
            .generated_at_ms = fs_compat.milliTimestamp(),
            .formulas = &.{},
            .casks = &.{},
        });
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    try outdated_mod.refreshSnapshot(allocator, &db, &api, cache_dir, null);
}
