//! malt — per-scope runners driven by the purge orchestrator.  Each
//! `runX` is an independent bounded context that owns its own database
//! handle, allocator plumbing, and dry-run branching.

const std = @import("std");
const fs_compat = @import("../../fs/compat.zig");
const schema = @import("../../db/schema.zig");
const output = @import("../../ui/output.zig");
const store_mod = @import("../../core/store.zig");
const deps_mod = @import("../../core/deps.zig");
const linker_mod = @import("../../core/linker.zig");
const cellar_mod = @import("../../core/cellar.zig");
const util = @import("util.zig");

const TierResult = util.TierResult;

// ── Tier: --store-orphans (was `gc`) ────────────────────────────────────────

pub fn runStoreOrphans(allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};

    var db = util.openDb(prefix) orelse {
        output.err("store-orphans: failed to open database", .{});
        return result;
    };
    defer db.close();
    schema.initSchema(&db) catch return result;

    var store = store_mod.Store.init(allocator, &db, prefix);
    var orphans_list = store.orphans() catch {
        output.err("store-orphans: failed to enumerate orphans", .{});
        return result;
    };
    defer {
        for (orphans_list.items) |item| allocator.free(item);
        orphans_list.deinit(allocator);
    }

    if (orphans_list.items.len == 0) {
        output.info("store-orphans: no orphaned store entries", .{});
        return result;
    }

    if (dry_run) {
        output.info("store-orphans: would remove {d} entry(s):", .{orphans_list.items.len});
    } else {
        output.info("store-orphans: removing {d} entry(s):", .{orphans_list.items.len});
    }

    for (orphans_list.items) |sha| {
        util.writeStderr("  ");
        util.writeStderr(sha);
        util.writeStderr("\n");
        if (!dry_run) {
            store.remove(sha) catch continue;
            result.removed += 1;
        } else {
            result.removed += 1;
        }
    }
    return result;
}

// ── Tier: --unused-deps (was `autoremove`) ──────────────────────────────────

pub fn runUnusedDeps(allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};

    var db = util.openDb(prefix) orelse {
        output.err("unused-deps: failed to open database", .{});
        return result;
    };
    defer db.close();
    schema.initSchema(&db) catch return result;

    const orphans = deps_mod.findOrphans(allocator, &db) catch {
        output.err("unused-deps: failed to find orphans", .{});
        return result;
    };
    defer {
        for (orphans) |o| allocator.free(o);
        allocator.free(orphans);
    }

    if (orphans.len == 0) {
        output.info("unused-deps: no orphaned dependencies", .{});
        return result;
    }

    if (dry_run) {
        output.info("unused-deps: would remove {d} package(s):", .{orphans.len});
        for (orphans) |name| {
            util.writeStderr("  ");
            util.writeStderr(name);
            util.writeStderr("\n");
        }
        result.removed = @intCast(orphans.len);
        return result;
    }

    output.info("unused-deps: removing {d} package(s):", .{orphans.len});

    var linker = linker_mod.Linker.init(allocator, &db, prefix);
    var store = store_mod.Store.init(allocator, &db, prefix);

    // Per-orphan removal is best-effort across all steps: a partially-linked
    // or partially-materialized keg must still be cleanable. Callers rely on
    // the DB `DELETE` as the authoritative removal signal; filesystem and
    // refcount side-effects converge on subsequent runs.
    for (orphans) |name| {
        var stmt = db.prepare("SELECT id, version, store_sha256 FROM kegs WHERE name = ?1;") catch continue;
        defer stmt.finalize();
        stmt.bindText(1, name) catch continue;

        if (stmt.step() catch false) {
            const keg_id = stmt.columnInt(0);
            const version_ptr = stmt.columnText(1);
            const sha_ptr = stmt.columnText(2);

            linker.unlink(keg_id) catch {};
            if (version_ptr) |v| {
                cellar_mod.remove(prefix, name, std.mem.sliceTo(v, 0)) catch {};
            }
            {
                var parent_buf: [512]u8 = undefined;
                const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch "";
                // Parent dir may be non-empty (sibling versions still installed).
                if (parent_path.len > 0) fs_compat.deleteDirAbsolute(parent_path) catch {};
            }
            if (sha_ptr) |s| {
                store.decrementRef(std.mem.sliceTo(s, 0)) catch {};
            }
            var del = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch continue;
            defer del.finalize();
            del.bindInt(1, keg_id) catch continue;
            _ = del.step() catch {};

            util.writeStderr("  ");
            util.writeStderr(name);
            util.writeStderr("\n");
            result.removed += 1;
        }
    }
    return result;
}

// ── Tier: --cache[=DAYS] (was `cleanup --prune=`) ───────────────────────────

pub fn runCache(allocator: std.mem.Allocator, cache_dir: []const u8, max_age_days: i64, dry_run: bool) !TierResult {
    _ = allocator;
    var result: TierResult = .{};
    output.info("cache: pruning entries older than {d} day(s) under {s}", .{ max_age_days, cache_dir });
    pruneCacheRecursive(cache_dir, max_age_days, dry_run, &result);
    return result;
}

fn pruneCacheRecursive(cache_dir: []const u8, max_age_days: i64, dry_run: bool, result: *TierResult) void {
    var dir = fs_compat.openDirAbsolute(cache_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    const now = fs_compat.timestamp();
    const max_age_secs = max_age_days * 86400;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            var sub_buf: [512]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ cache_dir, entry.name }) catch continue;
            pruneCacheRecursive(sub_path, max_age_days, dry_run, result);
            continue;
        }
        const stat = dir.statFile(entry.name) catch continue;
        const mtime_secs: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
        if (now - mtime_secs > max_age_secs) {
            if (dry_run) {
                output.info("  would prune: {s}/{s}", .{ cache_dir, entry.name });
            } else {
                dir.deleteFile(entry.name) catch continue;
                output.info("  pruned: {s}/{s}", .{ cache_dir, entry.name });
            }
            result.bytes += stat.size;
            result.removed += 1;
        }
    }
}

// ── Tier: --downloads (was `cleanup -s`) ────────────────────────────────────

pub fn runDownloads(allocator: std.mem.Allocator, cache_dir: []const u8, dry_run: bool) !TierResult {
    _ = allocator;
    var result: TierResult = .{};

    var path_buf: [512]u8 = undefined;
    const downloads_path = std.fmt.bufPrint(&path_buf, "{s}/downloads", .{cache_dir}) catch return result;

    var dir = fs_compat.openDirAbsolute(downloads_path, .{ .iterate = true }) catch {
        output.info("downloads: nothing to remove ({s} not present)", .{downloads_path});
        return result;
    };
    defer dir.close();

    if (dry_run) {
        output.info("downloads: would wipe {s}", .{downloads_path});
    } else {
        output.info("downloads: wiping {s}", .{downloads_path});
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) continue;
        const stat = dir.statFile(entry.name) catch continue;
        if (dry_run) {
            output.info("  would remove: {s}", .{entry.name});
        } else {
            dir.deleteFile(entry.name) catch continue;
            output.info("  removed: {s}", .{entry.name});
        }
        result.bytes += stat.size;
        result.removed += 1;
    }
    return result;
}

// ── Tier: --stale-casks ─────────────────────────────────────────────────────

pub fn runStaleCasks(allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};

    var db = util.openDb(prefix) orelse {
        output.info("stale-casks: no database — nothing to inspect", .{});
        return result;
    };
    defer db.close();

    // Cask download cache
    var cask_cache_buf: [512]u8 = undefined;
    const cask_cache_path = std.fmt.bufPrint(&cask_cache_buf, "{s}/cache/Cask", .{prefix}) catch return result;
    if (fs_compat.openDirAbsolute(cask_cache_path, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) continue;
            const name = entry.name;
            const token = blk: {
                for ([_][]const u8{ ".dmg", ".zip", ".pkg" }) |ext| {
                    if (std.mem.endsWith(u8, name, ext)) {
                        break :blk name[0 .. name.len - ext.len];
                    }
                }
                break :blk name;
            };

            const token_z = allocator.dupeZ(u8, token) catch continue;
            defer allocator.free(token_z);

            var stmt = db.prepare("SELECT token FROM casks WHERE token = ?1 LIMIT 1;") catch continue;
            defer stmt.finalize();
            stmt.bindText(1, token_z) catch continue;

            if (stmt.step() catch false) continue; // still installed

            const stat = dir.statFile(entry.name) catch continue;
            if (dry_run) {
                output.info("  stale-casks: would remove cache {s}", .{entry.name});
            } else {
                dir.deleteFile(entry.name) catch continue;
                output.info("  stale-casks: removed cache {s}", .{entry.name});
            }
            result.bytes += stat.size;
            result.removed += 1;
        }
    } else |_| {}

    // Caskroom orphans
    var caskroom_buf: [512]u8 = undefined;
    const caskroom_path = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom", .{prefix}) catch return result;
    if (fs_compat.openDirAbsolute(caskroom_path, .{ .iterate = true })) |dir_const| {
        var caskroom = dir_const;
        defer caskroom.close();

        var cr_iter = caskroom.iterate();
        while (cr_iter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;

            const token_z = allocator.dupeZ(u8, entry.name) catch continue;
            defer allocator.free(token_z);

            var stmt = db.prepare("SELECT token FROM casks WHERE token = ?1 LIMIT 1;") catch continue;
            defer stmt.finalize();
            stmt.bindText(1, token_z) catch continue;

            if (stmt.step() catch false) continue;

            var path_buf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&path_buf, "{s}/Caskroom/{s}", .{ prefix, entry.name }) catch continue;
            if (dry_run) {
                output.info("  stale-casks: would remove Caskroom/{s}", .{entry.name});
            } else {
                fs_compat.deleteTreeAbsolute(full) catch continue;
                output.info("  stale-casks: removed Caskroom/{s}", .{entry.name});
            }
            result.removed += 1;
        }
    } else |_| {}

    if (result.removed == 0) {
        output.info("stale-casks: nothing to remove", .{});
    }
    return result;
}

// ── Tier: --old-versions ────────────────────────────────────────────────────

pub fn runOldVersions(allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};

    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{prefix}) catch return result;

    var cellar_dir = fs_compat.openDirAbsolute(cellar_path, .{ .iterate = true }) catch {
        output.info("old-versions: no Cellar directory at {s}", .{cellar_path});
        return result;
    };
    defer cellar_dir.close();

    var iter = cellar_dir.iterate();
    while (iter.next() catch null) |formula_entry| {
        if (formula_entry.kind != .directory) continue;

        var formula_dir = cellar_dir.openDir(formula_entry.name, .{ .iterate = true }) catch continue;
        defer formula_dir.close();

        // Collect (name, mtime) for every version directory.
        const Version = struct { name: []u8, mtime: i128 };
        var versions: std.ArrayList(Version) = .empty;
        defer {
            for (versions.items) |v| allocator.free(v.name);
            versions.deinit(allocator);
        }

        var ver_iter = formula_dir.iterate();
        while (ver_iter.next() catch null) |ver_entry| {
            if (ver_entry.kind != .directory) continue;
            const stat = formula_dir.statFile(ver_entry.name) catch continue;
            const dup = allocator.dupe(u8, ver_entry.name) catch continue;
            versions.append(allocator, .{ .name = dup, .mtime = stat.mtime.nanoseconds }) catch {
                allocator.free(dup);
                continue;
            };
        }

        if (versions.items.len <= 1) continue;

        // Newest mtime wins — semver sort would be more correct but brittle
        // across upstream version strings.
        var newest_idx: usize = 0;
        for (versions.items, 0..) |v, idx| {
            if (v.mtime > versions.items[newest_idx].mtime) newest_idx = idx;
        }

        for (versions.items, 0..) |v, idx| {
            if (idx == newest_idx) continue;
            var path_buf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&path_buf, "{s}/Cellar/{s}/{s}", .{ prefix, formula_entry.name, v.name }) catch continue;
            const sz = util.pathSize(allocator, full);
            if (dry_run) {
                output.info("  old-versions: would remove {s}/{s}", .{ formula_entry.name, v.name });
            } else {
                fs_compat.deleteTreeAbsolute(full) catch continue;
                output.info("  old-versions: removed {s}/{s}", .{ formula_entry.name, v.name });
            }
            result.bytes += sz;
            result.removed += 1;
        }
    }

    if (result.removed == 0) {
        output.info("old-versions: nothing to remove", .{});
    }
    return result;
}
