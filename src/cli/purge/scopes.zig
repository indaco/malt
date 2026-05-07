//! malt — per-scope runners driven by the purge orchestrator.  Each
//! `runX` is an independent bounded context that owns its own database
//! handle, allocator plumbing, and dry-run branching.  Output flows
//! through a `Reporter`: header → items → footer.  The orchestrator
//! collects the `TierResult` returned here into a summary table.

const std = @import("std");
const AppCtx = @import("../../app_ctx.zig").AppCtx;
const schema = @import("../../db/schema.zig");
const sqlite = @import("../../db/sqlite.zig");
const output = @import("../../ui/output.zig");
const store_mod = @import("../../core/store.zig");
const deps_mod = @import("../../core/deps.zig");
const linker_mod = @import("../../core/linker.zig");
const cellar_mod = @import("../../core/cellar.zig");
const util = @import("util.zig");
const report = @import("report.zig");

const TierResult = util.TierResult;

// ── Tier: --store-orphans (was `gc`) ────────────────────────────────────────

pub fn runStoreOrphans(ctx: *const AppCtx, allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};
    var rep = report.Reporter.init("store-orphans", dry_run);
    rep.fmt = .short_hash;

    const io = ctx.io;
    var db = switch (util.openDbTri(io, prefix)) {
        .absent => {
            rep.empty("no database — nothing to inspect");
            return result;
        },
        .unreadable => |e| {
            output.err("store-orphans: cannot open database ({s})", .{@errorName(e)});
            result.status = .err;
            result.error_kind = "db_unreadable";
            return result;
        },
        .opened => |db_val| db_val,
    };
    defer db.close();
    schema.initSchema(&db) catch |e| {
        output.err("store-orphans: cannot init schema ({s})", .{@errorName(e)});
        result.status = .err;
        result.error_kind = "schema_init";
        return result;
    };

    var store = store_mod.Store.init(io, allocator, &db, prefix);
    var orphans_list = store.orphans() catch {
        output.err("store-orphans: failed to enumerate orphans", .{});
        result.status = .err;
        result.error_kind = "enumerate_orphans";
        return result;
    };
    defer {
        for (orphans_list.items) |item| allocator.free(item);
        orphans_list.deinit(allocator);
    }

    if (orphans_list.items.len == 0) {
        rep.empty("no orphaned store entries");
        return result;
    }

    rep.header(orphans_list.items.len, "entry", "entries");

    // Stat the entry before remove() so we can credit freed bytes — the
    // path disappears as soon as `store.remove` returns.
    for (orphans_list.items) |sha| {
        var path_buf: [512]u8 = undefined;
        const store_path = std.fmt.bufPrint(&path_buf, "{s}/store/{s}", .{ prefix, sha }) catch continue;
        const sz = util.pathSize(io, allocator, store_path);

        rep.item(sha);
        if (!dry_run) {
            store.remove(sha) catch continue;
        }
        result.removed += 1;
        result.bytes += sz;
    }
    rep.done(orphans_list.items.len);
    return result;
}

// ── Tier: --unused-deps (was `autoremove`) ──────────────────────────────────

pub fn runUnusedDeps(ctx: *const AppCtx, allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};
    var rep = report.Reporter.init("unused-deps", dry_run);

    var db = switch (util.openDbTri(ctx.io, prefix)) {
        .absent => {
            rep.empty("no database — nothing to inspect");
            return result;
        },
        .unreadable => |e| {
            output.err("unused-deps: cannot open database ({s})", .{@errorName(e)});
            result.status = .err;
            result.error_kind = "db_unreadable";
            return result;
        },
        .opened => |db_val| db_val,
    };
    defer db.close();
    schema.initSchema(&db) catch |e| {
        output.err("unused-deps: cannot init schema ({s})", .{@errorName(e)});
        result.status = .err;
        result.error_kind = "schema_init";
        return result;
    };

    const orphans = deps_mod.findOrphans(allocator, &db) catch {
        output.err("unused-deps: failed to find orphans", .{});
        result.status = .err;
        result.error_kind = "find_orphans";
        return result;
    };
    defer {
        for (orphans) |o| allocator.free(o);
        allocator.free(orphans);
    }

    if (orphans.len == 0) {
        rep.empty("no orphaned dependencies");
        return result;
    }

    rep.header(orphans.len, "package", "packages");

    if (dry_run) {
        for (orphans) |name| rep.item(name);
        rep.done(orphans.len);
        result.removed = @intCast(orphans.len);
        return result;
    }

    const io = ctx.io;
    var linker = linker_mod.Linker.init(io, allocator, &db, prefix);
    var store = store_mod.Store.init(io, allocator, &db, prefix);

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

            // Credit cellar bytes before unlink: removing the keg deletes
            // the directory we'd otherwise stat.
            if (version_ptr) |v| {
                var path_buf: [512]u8 = undefined;
                const cellar_path = std.fmt.bufPrint(&path_buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, std.mem.sliceTo(v, 0) }) catch "";
                if (cellar_path.len > 0) result.bytes += util.pathSize(io, allocator, cellar_path);
            }

            linker.unlink(keg_id) catch {};
            if (version_ptr) |v| {
                cellar_mod.remove(io, prefix, name, std.mem.sliceTo(v, 0)) catch {};
            }
            {
                var parent_buf: [512]u8 = undefined;
                const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch "";
                // Parent dir may be non-empty (sibling versions still installed).
                if (parent_path.len > 0) std.Io.Dir.deleteDirAbsolute(io, parent_path) catch {};
            }
            if (sha_ptr) |s| {
                store.decrementRef(std.mem.sliceTo(s, 0)) catch {};
            }
            var del = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch continue;
            defer del.finalize();
            del.bindInt(1, keg_id) catch continue;
            _ = del.step() catch {};

            rep.item(name);
            result.removed += 1;
        }
    }
    rep.done(orphans.len);
    return result;
}

// ── Tier: --cache[=DAYS] (was `cleanup --prune=`) ───────────────────────────

pub fn runCache(ctx: *const AppCtx, allocator: std.mem.Allocator, cache_dir: []const u8, max_age_days: i64, dry_run: bool) !TierResult {
    _ = allocator;
    var result: TierResult = .{};

    var rep = report.Reporter.init("cache", dry_run);
    rep.note("pruning entries older than {d} {s} under {s}", .{
        max_age_days,
        report.pluralize(@intCast(max_age_days), "day", "days"),
        cache_dir,
    });
    pruneCacheRecursive(ctx.io, cache_dir, max_age_days, dry_run, &result, &rep);
    rep.done(result.removed);
    return result;
}

fn pruneCacheRecursive(io: std.Io, cache_dir: []const u8, max_age_days: i64, dry_run: bool, result: *TierResult, rep: *report.Reporter) void {
    var dir = std.Io.Dir.openDirAbsolute(io, cache_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const now = std.Io.Clock.real.now(io).toSeconds();
    const max_age_secs = max_age_days * 86400;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            var sub_buf: [512]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ cache_dir, entry.name }) catch continue;
            pruneCacheRecursive(io, sub_path, max_age_days, dry_run, result, rep);
            continue;
        }
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const mtime_secs: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
        if (now - mtime_secs > max_age_secs) {
            if (!dry_run) dir.deleteFile(io, entry.name) catch continue;
            // Full path so users (and the smoke tests) can see WHERE the
            // file lived; the leaf alone hides path-of-cleanup hot spots.
            var label_buf: [768]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{s}/{s}", .{ cache_dir, entry.name }) catch entry.name;
            rep.item(label);
            result.bytes += stat.size;
            result.removed += 1;
        }
    }
}

// ── Tier: --downloads (was `cleanup -s`) ────────────────────────────────────

pub fn runDownloads(ctx: *const AppCtx, allocator: std.mem.Allocator, cache_dir: []const u8, dry_run: bool) !TierResult {
    _ = allocator;
    var result: TierResult = .{};
    const io = ctx.io;

    var rep = report.Reporter.init("downloads", dry_run);

    var path_buf: [512]u8 = undefined;
    const downloads_path = std.fmt.bufPrint(&path_buf, "{s}/downloads", .{cache_dir}) catch return result;

    var dir = std.Io.Dir.openDirAbsolute(io, downloads_path, .{ .iterate = true }) catch {
        rep.empty("nothing to remove (downloads dir not present)");
        return result;
    };
    defer dir.close(io);

    // Two-pass: count first so the header reads accurately, then remove.
    // Cheap because the directory is already cached after the open above.
    var entries_seen: usize = 0;
    var ent_iter = dir.iterate();
    while (ent_iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        entries_seen += 1;
    }

    if (entries_seen == 0) {
        rep.empty("nothing to remove");
        return result;
    }

    rep.header(entries_seen, "file", "files");

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (!dry_run) dir.deleteFile(io, entry.name) catch continue;
        rep.item(entry.name);
        result.bytes += stat.size;
        result.removed += 1;
    }
    rep.done(entries_seen);
    return result;
}

// ── Tier: --stale-casks ─────────────────────────────────────────────────────

pub fn runStaleCasks(ctx: *const AppCtx, allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};
    const io = ctx.io;

    var rep = report.Reporter.init("stale-casks", dry_run);

    var db = switch (util.openDbTri(io, prefix)) {
        .absent => {
            rep.empty("no database — nothing to inspect");
            return result;
        },
        .unreadable => |e| {
            output.err("stale-casks: cannot open database ({s})", .{@errorName(e)});
            result.status = .err;
            result.error_kind = "db_unreadable";
            return result;
        },
        .opened => |db_val| db_val,
    };
    defer db.close();
    schema.initSchema(&db) catch |e| {
        output.err("stale-casks: cannot init schema ({s})", .{@errorName(e)});
        result.status = .err;
        result.error_kind = "schema_init";
        return result;
    };

    // Single reusable lookup for both passes — they ask the same
    // question. A persistent prepare failure (schema drift, lock held)
    // would otherwise empty the candidate set silently.
    var lookup = db.prepare("SELECT token FROM casks WHERE token = ?1 LIMIT 1;") catch |e| {
        output.err("stale-casks: cannot prepare cask lookup ({s})", .{@errorName(e)});
        result.status = .err;
        result.error_kind = "db_prepare";
        return result;
    };
    defer lookup.finalize();

    // Collect candidates first so we can emit a single header line with
    // an accurate count before printing the per-item bullets.
    const Candidate = struct {
        kind: enum { cache_file, caskroom_dir },
        name: []u8, // owned
        size: u64,
    };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |c| allocator.free(c.name);
        candidates.deinit(allocator);
    }

    // Cask download cache
    var cask_cache_buf: [512]u8 = undefined;
    const cask_cache_path = std.fmt.bufPrint(&cask_cache_buf, "{s}/cache/Cask", .{prefix}) catch return result;
    if (std.Io.Dir.openDirAbsolute(io, cask_cache_path, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(io);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
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

            lookup.reset() catch {};
            lookup.bindText(1, token_z) catch |e| {
                output.warn("stale-casks: skipping {s}: bind failed ({s})", .{ token, @errorName(e) });
                continue;
            };
            if (lookup.step() catch false) continue; // still installed

            const stat = dir.statFile(io, entry.name, .{}) catch continue;
            const dup = allocator.dupe(u8, entry.name) catch continue;
            candidates.append(allocator, .{ .kind = .cache_file, .name = dup, .size = stat.size }) catch {
                allocator.free(dup);
                continue;
            };
        }
    } else |_| {}

    // Caskroom orphans
    var caskroom_buf: [512]u8 = undefined;
    const caskroom_path = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom", .{prefix}) catch return result;
    if (std.Io.Dir.openDirAbsolute(io, caskroom_path, .{ .iterate = true })) |dir_const| {
        var caskroom = dir_const;
        defer caskroom.close(io);

        var cr_iter = caskroom.iterate();
        while (cr_iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            const token_z = allocator.dupeZ(u8, entry.name) catch continue;
            defer allocator.free(token_z);

            lookup.reset() catch {};
            lookup.bindText(1, token_z) catch |e| {
                output.warn("stale-casks: skipping {s}: bind failed ({s})", .{ entry.name, @errorName(e) });
                continue;
            };
            if (lookup.step() catch false) continue;

            var path_buf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&path_buf, "{s}/Caskroom/{s}", .{ prefix, entry.name }) catch continue;
            const sz = util.pathSize(io, allocator, full);
            const dup = allocator.dupe(u8, entry.name) catch continue;
            candidates.append(allocator, .{ .kind = .caskroom_dir, .name = dup, .size = sz }) catch {
                allocator.free(dup);
                continue;
            };
        }
    } else |_| {}

    if (candidates.items.len == 0) {
        rep.empty("nothing to remove");
        return result;
    }

    rep.header(candidates.items.len, "entry", "entries");

    for (candidates.items) |c| {
        switch (c.kind) {
            .cache_file => {
                if (!dry_run) {
                    var dir = std.Io.Dir.openDirAbsolute(io, cask_cache_path, .{}) catch continue;
                    defer dir.close(io);
                    dir.deleteFile(io, c.name) catch continue;
                }
                rep.item(c.name);
            },
            .caskroom_dir => {
                if (!dry_run) {
                    var path_buf: [512]u8 = undefined;
                    const full = std.fmt.bufPrint(&path_buf, "{s}/Caskroom/{s}", .{ prefix, c.name }) catch continue;
                    std.Io.Dir.cwd().deleteTree(io, full) catch continue;
                }
                rep.item(c.name);
            },
        }
        result.removed += 1;
        result.bytes += c.size;
    }
    rep.done(candidates.items.len);
    return result;
}

// ── Tier: --old-versions ────────────────────────────────────────────────────

pub fn runOldVersions(ctx: *const AppCtx, allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};
    const io = ctx.io;

    var rep = report.Reporter.init("old-versions", dry_run);

    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{prefix}) catch return result;

    var cellar_dir = std.Io.Dir.openDirAbsolute(io, cellar_path, .{ .iterate = true }) catch {
        rep.empty("no Cellar directory");
        return result;
    };
    defer cellar_dir.close(io);

    // Two-pass: collect candidates first so the header count matches what
    // the user is about to see scrolled past.
    const Candidate = struct {
        formula: []u8, // owned
        version: []u8, // owned
        size: u64,
    };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |c| {
            allocator.free(c.formula);
            allocator.free(c.version);
        }
        candidates.deinit(allocator);
    }

    var iter = cellar_dir.iterate();
    while (iter.next(io) catch null) |formula_entry| {
        if (formula_entry.kind != .directory) continue;

        var formula_dir = cellar_dir.openDir(io, formula_entry.name, .{ .iterate = true }) catch continue;
        defer formula_dir.close(io);

        const Version = struct { name: []u8, mtime: i128 };
        var versions: std.ArrayList(Version) = .empty;
        defer {
            for (versions.items) |v| allocator.free(v.name);
            versions.deinit(allocator);
        }

        var ver_iter = formula_dir.iterate();
        while (ver_iter.next(io) catch null) |ver_entry| {
            if (ver_entry.kind != .directory) continue;
            const stat = formula_dir.statFile(io, ver_entry.name, .{}) catch continue;
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
            const sz = util.pathSize(io, allocator, full);

            const fdup = allocator.dupe(u8, formula_entry.name) catch continue;
            const vdup = allocator.dupe(u8, v.name) catch {
                allocator.free(fdup);
                continue;
            };
            candidates.append(allocator, .{ .formula = fdup, .version = vdup, .size = sz }) catch {
                allocator.free(fdup);
                allocator.free(vdup);
                continue;
            };
        }
    }

    if (candidates.items.len == 0) {
        rep.empty("nothing to remove");
        return result;
    }

    rep.header(candidates.items.len, "version", "versions");

    var label_buf: [256]u8 = undefined;
    for (candidates.items) |c| {
        if (!dry_run) {
            var path_buf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&path_buf, "{s}/Cellar/{s}/{s}", .{ prefix, c.formula, c.version }) catch continue;
            std.Io.Dir.cwd().deleteTree(io, full) catch continue;
        }
        const label = std.fmt.bufPrint(&label_buf, "{s}/{s}", .{ c.formula, c.version }) catch c.formula;
        rep.item(label);
        result.bytes += c.size;
        result.removed += 1;
    }
    rep.done(candidates.items.len);
    return result;
}

// ── inline unit tests ──────────────────────────────────────────────────────

const testing = std.testing;
const fs_test_io = std.Options.debug_io;

test "runStaleCasks surfaces db prepare failure when the casks table shape is wrong" {
    // Pre-existing `casks` table with the wrong shape: `initSchema`'s
    // CREATE IF NOT EXISTS is a no-op, the lookup statement cannot
    // prepare, and the silent `catch continue` would have emptied the
    // candidate set and reported a clean no-op. Pin the loud signal.
    const allocator = testing.allocator;

    const prefix = "/tmp/malt_runStaleCasks_prepare_err";
    std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/db");
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/cache/Cask");

    {
        var db = try sqlite.Database.open(prefix ++ "/db/malt.db");
        defer db.close();
        try db.exec("CREATE TABLE casks (id INTEGER);");
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(fs_test_io, prefix ++ "/cache/Cask/ghost.dmg", .{ .truncate = true });
        defer f.close(fs_test_io);
        try f.writeStreamingAll(fs_test_io, "x");
    }

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    const ctx = AppCtx{ .io = fs_test_io, .environ = .empty };
    const result = try runStaleCasks(&ctx, allocator, prefix, true);

    try testing.expectEqual(util.ScopeStatus.err, result.status);
    try testing.expectEqualStrings("db_prepare", result.error_kind orelse "");
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "stale-casks") != null);
}

test "runStaleCasks self-heals a schema-less db rather than reporting it as a fault" {
    // A bare DB file with no schema must not surface as a `db_prepare`
    // fault — the function self-heals via `schema.initSchema`, matching
    // its sibling scopes (`runStoreOrphans`, `runUnusedDeps`).
    const allocator = testing.allocator;

    const prefix = "/tmp/malt_runStaleCasks_self_heal";
    std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/db");

    {
        var db = try sqlite.Database.open(prefix ++ "/db/malt.db");
        db.close();
    }

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    const ctx = AppCtx{ .io = fs_test_io, .environ = .empty };
    const result = try runStaleCasks(&ctx, allocator, prefix, true);

    try testing.expectEqual(util.ScopeStatus.ok, result.status);
    try testing.expect(result.error_kind == null);
    try testing.expectEqual(@as(u32, 0), result.removed);
}
