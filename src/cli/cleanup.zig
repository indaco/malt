//! malt — cleanup command
//! Remove old versions, prune caches.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var dry_run = false;
    var prune_days: ?i64 = null;
    var scrub = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-s")) {
            scrub = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else if (std.mem.startsWith(u8, arg, "--prune=")) {
            const val = arg["--prune=".len..];
            prune_days = std.fmt.parseInt(i64, val, 10) catch null;
        } else if (std.mem.eql(u8, arg, "--prune")) {
            if (i + 1 < args.len) {
                i += 1;
                prune_days = std.fmt.parseInt(i64, args[i], 10) catch null;
            }
        }
    }

    const prefix = atomic.maltPrefix();
    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to determine cache directory", .{});
        return;
    };
    defer allocator.free(cache_dir);

    var total_freed: u64 = 0;

    // Prune old cache entries
    if (prune_days) |days| {
        total_freed += pruneCache(cache_dir, days, dry_run);
    }

    // Scrub downloads cache
    if (scrub) {
        total_freed += scrubDownloads(cache_dir, dry_run);
    }

    // Clean old Cellar versions (keep only latest per formula)
    total_freed += cleanOldVersions(allocator, prefix, dry_run);

    if (dry_run) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Would free approximately {d} bytes (dry run)", .{total_freed}) catch return;
        output.info("{s}", .{msg});
    } else {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Freed approximately {d} bytes", .{total_freed}) catch return;
        output.info("{s}", .{msg});
    }
}

fn pruneCache(cache_dir: []const u8, max_age_days: i64, dry_run: bool) u64 {
    var dir = std.fs.openDirAbsolute(cache_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();

    const now = std.time.timestamp();
    const max_age_secs = max_age_days * 86400;
    var freed: u64 = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) continue;
        const stat = dir.statFile(entry.name) catch continue;
        const mtime_secs: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
        if (now - mtime_secs > max_age_secs) {
            freed += stat.size;
            if (!dry_run) {
                dir.deleteFile(entry.name) catch {};
            }
        }
    }

    return freed;
}

fn scrubDownloads(cache_dir: []const u8, dry_run: bool) u64 {
    var path_buf: [512]u8 = undefined;
    const downloads_path = std.fmt.bufPrint(&path_buf, "{s}/downloads", .{cache_dir}) catch return 0;

    var dir = std.fs.openDirAbsolute(downloads_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var freed: u64 = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) continue;
        const stat = dir.statFile(entry.name) catch continue;
        freed += stat.size;
        if (!dry_run) {
            dir.deleteFile(entry.name) catch {};
        }
    }

    return freed;
}

fn cleanOldVersions(allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) u64 {
    _ = allocator;

    // Open Cellar directory and look for formulas with multiple versions
    var cellar_path_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_path_buf, "{s}/Cellar", .{prefix}) catch return 0;

    var cellar_dir = std.fs.openDirAbsolute(cellar_path, .{ .iterate = true }) catch return 0;
    defer cellar_dir.close();

    const freed: u64 = 0;
    var iter = cellar_dir.iterate();
    while (iter.next() catch null) |formula_entry| {
        if (formula_entry.kind != .directory) continue;

        // For each formula, list version directories
        var formula_dir = cellar_dir.openDir(formula_entry.name, .{ .iterate = true }) catch continue;
        defer formula_dir.close();

        // Count versions — if only one, skip
        var count: u32 = 0;
        var ver_iter = formula_dir.iterate();
        while (ver_iter.next() catch null) |ver_entry| {
            if (ver_entry.kind == .directory) count += 1;
        }

        if (count <= 1) continue;

        // Multiple versions exist — remove all but the latest (by mtime)
        // For simplicity, we just report the opportunity
        if (!dry_run) {
            output.info("Multiple versions of {s} found ({d} versions)", .{ formula_entry.name, count });
        }
        // Actual old version cleanup would require sorting by version
        // and removing older ones. For safety, we only report here.
    }

    return freed;
}
