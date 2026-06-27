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
const cask_mod = @import("../../core/cask.zig");
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

    const io = ctx.io;

    // Defense-in-depth: never reap a dep that a still-installed keg's
    // Mach-O actually links. Its `dependencies` edge may have been lost
    // (e.g. an upgrade that predated edge re-recording), so the DB calls
    // it an orphan while the binary still needs it — the binary wins.
    var removable: std.ArrayList([]const u8) = .empty;
    defer removable.deinit(allocator);
    for (orphans) |name| {
        if (orphanStillLinked(io, allocator, &db, name)) {
            rep.note("keeping {s} — still linked by an installed package", .{name});
        } else {
            removable.append(allocator, name) catch {};
        }
    }

    if (removable.items.len == 0) return result;

    rep.header(removable.items.len, "package", "packages");

    if (dry_run) {
        for (removable.items) |name| rep.item(name);
        rep.done(removable.items.len);
        result.removed = @intCast(removable.items.len);
        return result;
    }

    var linker = linker_mod.Linker.init(io, allocator, &db, prefix);
    var store = store_mod.Store.init(io, allocator, &db, prefix);

    // Per-orphan removal is best-effort across all steps: a partially-linked
    // or partially-materialized keg must still be cleanable. Callers rely on
    // the DB `DELETE` as the authoritative removal signal; filesystem and
    // refcount side-effects converge on subsequent runs.
    for (removable.items) |name| {
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
    rep.done(removable.items.len);
    return result;
}

/// True iff some installed keg other than `name` carries a Mach-O hard
/// link into `opt/<name>/`. The orphan scan trusts the `dependencies`
/// table; this read-only fallback trusts the binaries, so a dropped edge
/// can't get a still-linked dependency deleted. Best-effort: any DB or
/// I/O failure reads as "not linked" so cleanup keeps working.
///
/// ponytail: O(orphans × installed-kegs) with first-match short-circuit.
/// Only runs when orphans exist (rare) so it's fine; if cleanup ever gets
/// slow on huge prefixes, hoist to a single pass collecting the linked
/// opt-name set once.
fn orphanStillLinked(io: std.Io, allocator: std.mem.Allocator, db: *sqlite.Database, name: []const u8) bool {
    var needle_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "/opt/{s}/", .{name}) catch return false;

    var stmt = db.prepare("SELECT cellar_path FROM kegs WHERE name != ?1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    while (stmt.step() catch false) {
        const cp = stmt.columnText(0) orelse continue;
        if (cellar_mod.cellarLinksPath(io, allocator, std.mem.sliceTo(cp, 0), needle)) return true;
    }
    return false;
}

// ── Tier: --cache[=DAYS] (was `cleanup --prune=`) ───────────────────────────

pub fn runCache(ctx: *const AppCtx, cache_dir: []const u8, max_age_days: i64, dry_run: bool) !TierResult {
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

pub fn runDownloads(ctx: *const AppCtx, cache_dir: []const u8, dry_run: bool) !TierResult {
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

// Single shape for both `old-versions` passes. `kind` distinguishes
// keg dirs in `Cellar/<formula>/<version>` from cask history rows in
// `cask_versions` — they share the same report row but route through
// different sweep paths.
const OldVersionCandidate = struct {
    kind: enum { cellar, cask },
    name: []u8, // owned: formula name (cellar) or cask token
    version: []u8, // owned
    size: u64,
};

pub fn runOldVersions(ctx: *const AppCtx, allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};
    const io = ctx.io;

    var rep = report.Reporter.init("old-versions", dry_run);

    var candidates: std.ArrayList(OldVersionCandidate) = .empty;
    defer {
        for (candidates.items) |c| {
            allocator.free(c.name);
            allocator.free(c.version);
        }
        candidates.deinit(allocator);
    }

    try collectCellarOldVersions(io, allocator, prefix, &candidates);
    collectCaskOldVersions(io, allocator, prefix, &candidates, &result);

    if (candidates.items.len == 0) {
        rep.empty("nothing to remove");
        return result;
    }

    rep.header(candidates.items.len, "version", "versions");

    // Reopen the DB only when the cask pass actually found rows — the
    // cellar-only case stays DB-free, matching the pre-T-038 shape.
    var db_opt: ?sqlite.Database = blk: {
        for (candidates.items) |c| {
            if (c.kind == .cask) break :blk reopenDbForRowDeletes(io, prefix, &result);
        }
        break :blk null;
    };
    defer if (db_opt) |*db| db.close();

    var label_buf: [256]u8 = undefined;
    for (candidates.items) |c| {
        const label = std.fmt.bufPrint(&label_buf, "{s}/{s}", .{ c.name, c.version }) catch c.name;
        switch (c.kind) {
            .cellar => {
                if (!dry_run) {
                    var path_buf: [512]u8 = undefined;
                    const full = std.fmt.bufPrint(&path_buf, "{s}/Cellar/{s}/{s}", .{ prefix, c.name, c.version }) catch continue;
                    std.Io.Dir.cwd().deleteTree(io, full) catch continue;
                }
                rep.item(label);
                result.bytes += c.size;
                result.removed += 1;
            },
            .cask => {
                if (!dry_run) {
                    if (!sweepCaskOldVersion(io, prefix, c.name, c.version)) continue;
                    if (db_opt) |*db| deleteCaskVersionRow(db, c.name, c.version);
                }
                rep.item(label);
                result.bytes += c.size;
                result.removed += 1;
            },
        }
    }
    rep.done(candidates.items.len);
    return result;
}

fn collectCellarOldVersions(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    candidates: *std.ArrayList(OldVersionCandidate),
) !void {
    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{prefix}) catch return;

    var cellar_dir = std.Io.Dir.openDirAbsolute(io, cellar_path, .{ .iterate = true }) catch return;
    defer cellar_dir.close(io);

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
            candidates.append(allocator, .{ .kind = .cellar, .name = fdup, .version = vdup, .size = sz }) catch {
                allocator.free(fdup);
                allocator.free(vdup);
                continue;
            };
        }
    }
}

// Walk `cask_versions` for rows whose version isn't the currently-
// installed cask. Best-effort: an absent DB (fresh prefix, no install
// yet) is a clean skip, not a fault.
fn collectCaskOldVersions(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    candidates: *std.ArrayList(OldVersionCandidate),
    result: *TierResult,
) void {
    var db = switch (util.openDbTri(io, prefix)) {
        .absent => return,
        .unreadable => |e| {
            output.warn("old-versions: cannot open database for cask history ({s})", .{@errorName(e)});
            result.status = .err;
            result.error_kind = "db_unreadable";
            return;
        },
        .opened => |db_val| db_val,
    };
    defer db.close();
    schema.initSchema(&db) catch |e| {
        output.warn("old-versions: cannot init schema for cask history ({s})", .{@errorName(e)});
        result.status = .err;
        result.error_kind = "schema_init";
        return;
    };

    // INNER JOIN drops tokens that have history rows but no current
    // install (uninstall already wiped that case); != selects every
    // history row whose version no longer matches the live one.
    var stmt = db.prepare(
        \\SELECT cv.token, cv.version
        \\FROM cask_versions cv
        \\JOIN casks c ON c.token = cv.token
        \\WHERE cv.version != c.version;
    ) catch |e| {
        output.warn("old-versions: cannot prepare cask history query ({s})", .{@errorName(e)});
        result.status = .err;
        result.error_kind = "db_prepare";
        return;
    };
    defer stmt.finalize();

    while (stmt.step() catch false) {
        const token_ptr = stmt.columnText(0) orelse continue;
        const version_ptr = stmt.columnText(1) orelse continue;
        const token = std.mem.sliceTo(token_ptr, 0);
        const version = std.mem.sliceTo(version_ptr, 0);

        // Size the on-disk footprint: Caskroom dir + every per-version
        // cache file we'd remove. Computed up front so the report's
        // freed-bytes counter is accurate even on dry-run.
        const sz = caskVersionFootprint(io, allocator, prefix, token, version);

        const tdup = allocator.dupe(u8, token) catch continue;
        const vdup = allocator.dupe(u8, version) catch {
            allocator.free(tdup);
            continue;
        };
        candidates.append(allocator, .{ .kind = .cask, .name = tdup, .version = vdup, .size = sz }) catch {
            allocator.free(tdup);
            allocator.free(vdup);
            continue;
        };
    }
}

fn reopenDbForRowDeletes(io: std.Io, prefix: []const u8, result: *TierResult) ?sqlite.Database {
    return switch (util.openDbTri(io, prefix)) {
        .absent => null,
        .unreadable => |e| blk: {
            output.warn("old-versions: cannot reopen database for history rows ({s})", .{@errorName(e)});
            result.status = .err;
            result.error_kind = "db_unreadable";
            break :blk null;
        },
        .opened => |db_val| db_val,
    };
}

fn caskVersionFootprint(io: std.Io, allocator: std.mem.Allocator, prefix: []const u8, token: []const u8, version: []const u8) u64 {
    var total: u64 = 0;
    var path_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&path_buf, "{s}/Caskroom/{s}/{s}", .{ prefix, token, version })) |caskroom_path| {
        total += util.pathSize(io, allocator, caskroom_path);
    } else |_| {}

    for ([_][]const u8{ ".dmg", ".zip", ".pkg", ".tar.gz" }) |ext| {
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/cache/Cask/{s}-{s}{s}", .{ prefix, token, version, ext }) catch continue;
        if (std.Io.Dir.cwd().statFile(io, cache_path, .{})) |st| {
            total += st.size;
        } else |_| {}
    }
    return total;
}

// Try the filesystem-side removal first; the history row delete is
// only safe after we've actually cleared disk. Returns true when both
// the Caskroom dir and every per-version cache file are gone (either
// removed here or already absent). A live file we cannot remove (e.g.
// read-only mount) gates the row so a future writable run can finish.
fn sweepCaskOldVersion(io: std.Io, prefix: []const u8, token: []const u8, version: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&path_buf, "{s}/Caskroom/{s}/{s}", .{ prefix, token, version })) |caskroom_path| {
        if (std.Io.Dir.accessAbsolute(io, caskroom_path, .{})) |_| {
            std.Io.Dir.cwd().deleteTree(io, caskroom_path) catch return false;
        } else |_| {}
    } else |_| {}

    return cask_mod.deletePerVersionCacheFile(io, prefix, token, version);
}

fn deleteCaskVersionRow(db: *sqlite.Database, token: []const u8, version: []const u8) void {
    var stmt = db.prepare("DELETE FROM cask_versions WHERE token = ?1 AND version = ?2;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, token) catch return;
    stmt.bindText(2, version) catch return;
    _ = stmt.step() catch {};
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

// ── runOldVersions cask history sweep ──────────────────────────────────────
//
// T-038 extends the Cellar-only walker so cask per-version artefacts
// (`cache/Cask/<token>-<version>.<ext>`, `Caskroom/<token>/<version>/`)
// and the matching `cask_versions` rows get the same "non-current wins,
// older versions go" treatment. Pinning the contract here so a future
// refactor cannot silently drop the cask branch.

fn seedCaskVersionRow(
    db: *sqlite.Database,
    token: []const u8,
    version: []const u8,
    artifact_type: []const u8,
) !void {
    var stmt = try db.prepare(
        \\INSERT INTO cask_versions (token, version, url, sha256, artifact_type, cache_path)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6);
    );
    defer stmt.finalize();
    try stmt.bindText(1, token);
    try stmt.bindText(2, version);
    try stmt.bindText(3, "https://example.invalid/dummy");
    try stmt.bindNull(4);
    try stmt.bindText(5, artifact_type);
    try stmt.bindNull(6);
    _ = try stmt.step();
}

fn seedCurrentCask(db: *sqlite.Database, token: []const u8, version: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT INTO casks (token, name, version, url, sha256, app_path, auto_updates)
        \\VALUES (?1, ?1, ?2, 'https://example.invalid/dummy', NULL, NULL, 0);
    );
    defer stmt.finalize();
    try stmt.bindText(1, token);
    try stmt.bindText(2, version);
    _ = try stmt.step();
}

fn touchFile(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, "x");
}

fn rowCount(db: *sqlite.Database, token: []const u8) !i64 {
    var stmt = try db.prepare("SELECT COUNT(*) FROM cask_versions WHERE token = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, token);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

test "runOldVersions sweeps non-current cask per-version cache + caskroom + history" {
    // Two history rows for `flux`: one current (v2), one stale (v1).
    // After a live run the stale cache file and Caskroom version dir
    // must be gone, the stale history row deleted, and counters must
    // reflect at least the cask removal.
    const allocator = testing.allocator;

    const prefix = "/tmp/malt_runOldVersions_cask_sweep";
    std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/db");
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/cache/Cask");

    {
        var db = try sqlite.Database.open(prefix ++ "/db/malt.db");
        defer db.close();
        try schema.initSchema(&db);
        try seedCurrentCask(&db, "flux", "2.0");
        try seedCaskVersionRow(&db, "flux", "2.0", "dmg");
        try seedCaskVersionRow(&db, "flux", "1.0", "dmg");
    }

    try touchFile(fs_test_io, prefix ++ "/cache/Cask/flux-2.0.dmg");
    try touchFile(fs_test_io, prefix ++ "/cache/Cask/flux-1.0.dmg");
    try touchFile(fs_test_io, prefix ++ "/Caskroom/flux/2.0/.metadata");
    try touchFile(fs_test_io, prefix ++ "/Caskroom/flux/1.0/.metadata");

    const ctx = AppCtx{ .io = fs_test_io, .environ = .empty };
    const result = try runOldVersions(&ctx, allocator, prefix, false);

    try testing.expectEqual(util.ScopeStatus.ok, result.status);
    try testing.expect(result.removed >= 1);

    // Current artefacts survive.
    try std.Io.Dir.accessAbsolute(fs_test_io, prefix ++ "/cache/Cask/flux-2.0.dmg", .{});
    try std.Io.Dir.accessAbsolute(fs_test_io, prefix ++ "/Caskroom/flux/2.0", .{});

    // Stale artefacts gone.
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(fs_test_io, prefix ++ "/cache/Cask/flux-1.0.dmg", .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(fs_test_io, prefix ++ "/Caskroom/flux/1.0", .{}),
    );

    // History row deleted; current row preserved.
    {
        var db = try sqlite.Database.open(prefix ++ "/db/malt.db");
        defer db.close();
        try testing.expectEqual(@as(i64, 1), try rowCount(&db, "flux"));
    }
}

test "runOldVersions --dry-run reports cask candidates without touching disk or db" {
    const allocator = testing.allocator;

    const prefix = "/tmp/malt_runOldVersions_cask_dry_run";
    std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/db");
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/cache/Cask");

    {
        var db = try sqlite.Database.open(prefix ++ "/db/malt.db");
        defer db.close();
        try schema.initSchema(&db);
        try seedCurrentCask(&db, "flux", "2.0");
        try seedCaskVersionRow(&db, "flux", "2.0", "dmg");
        try seedCaskVersionRow(&db, "flux", "1.0", "dmg");
    }

    try touchFile(fs_test_io, prefix ++ "/cache/Cask/flux-1.0.dmg");
    try touchFile(fs_test_io, prefix ++ "/Caskroom/flux/1.0/.metadata");

    const ctx = AppCtx{ .io = fs_test_io, .environ = .empty };
    const result = try runOldVersions(&ctx, allocator, prefix, true);

    try testing.expectEqual(util.ScopeStatus.ok, result.status);
    try testing.expect(result.removed >= 1);

    // Dry-run preserves everything.
    try std.Io.Dir.accessAbsolute(fs_test_io, prefix ++ "/cache/Cask/flux-1.0.dmg", .{});
    try std.Io.Dir.accessAbsolute(fs_test_io, prefix ++ "/Caskroom/flux/1.0", .{});

    var db = try sqlite.Database.open(prefix ++ "/db/malt.db");
    defer db.close();
    try testing.expectEqual(@as(i64, 2), try rowCount(&db, "flux"));
}

test "runOldVersions on already-swept cask state is a clean no-op" {
    // After a successful live run the second invocation must report
    // zero removals — no missing-row warnings, no errored status. Pins
    // the idempotence acceptance criterion.
    const allocator = testing.allocator;

    const prefix = "/tmp/malt_runOldVersions_cask_noop";
    std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/db");
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/cache/Cask");

    {
        var db = try sqlite.Database.open(prefix ++ "/db/malt.db");
        defer db.close();
        try schema.initSchema(&db);
        try seedCurrentCask(&db, "flux", "2.0");
        try seedCaskVersionRow(&db, "flux", "2.0", "dmg");
        try seedCaskVersionRow(&db, "flux", "1.0", "dmg");
    }
    try touchFile(fs_test_io, prefix ++ "/cache/Cask/flux-1.0.dmg");
    try touchFile(fs_test_io, prefix ++ "/Caskroom/flux/1.0/.metadata");

    const ctx = AppCtx{ .io = fs_test_io, .environ = .empty };
    _ = try runOldVersions(&ctx, allocator, prefix, false);
    const second = try runOldVersions(&ctx, allocator, prefix, false);

    try testing.expectEqual(util.ScopeStatus.ok, second.status);
    try testing.expectEqual(@as(u32, 0), second.removed);
}

test "runOldVersions ignores pin status when sweeping old cask versions" {
    // Pinned cask: current row stays in `casks`. Pin must not bleed
    // into the history sweep — old versions are still eligible for
    // removal, matching the Cellar-side policy.
    const allocator = testing.allocator;

    const prefix = "/tmp/malt_runOldVersions_cask_pinned";
    std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/db");
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/cache/Cask");

    {
        var db = try sqlite.Database.open(prefix ++ "/db/malt.db");
        defer db.close();
        try schema.initSchema(&db);
        // Insert with auto_updates=1 to simulate a held cask; the cask
        // schema does not carry a `pinned` column itself, so the proxy
        // here is "user-flagged-as-managed" via auto_updates.
        var stmt = try db.prepare(
            \\INSERT INTO casks (token, name, version, url, sha256, app_path, auto_updates)
            \\VALUES ('flux', 'flux', '2.0', 'https://example.invalid/dummy', NULL, NULL, 1);
        );
        defer stmt.finalize();
        _ = try stmt.step();
        try seedCaskVersionRow(&db, "flux", "2.0", "dmg");
        try seedCaskVersionRow(&db, "flux", "1.0", "dmg");
    }
    try touchFile(fs_test_io, prefix ++ "/cache/Cask/flux-1.0.dmg");
    try touchFile(fs_test_io, prefix ++ "/Caskroom/flux/1.0/.metadata");

    const ctx = AppCtx{ .io = fs_test_io, .environ = .empty };
    const result = try runOldVersions(&ctx, allocator, prefix, false);

    try testing.expectEqual(util.ScopeStatus.ok, result.status);
    try testing.expect(result.removed >= 1);
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(fs_test_io, prefix ++ "/cache/Cask/flux-1.0.dmg", .{}),
    );
}

// Build a minimal Mach-O carrying one LC_LOAD_DYLIB that names `dylib`,
// and write it at `path`. Lets the linkage-guard test stand in for a
// relocated bottle binary without shipping a real one.
fn writeFakeDylibLinker(io: std.Io, path: []const u8, dylib: [:0]const u8) !void {
    const macho = std.macho;
    const lc_size = @sizeOf(macho.dylib_command);
    const name_offset: u32 = @intCast(lc_size);
    const cmdsize: u32 = @intCast(lc_size + dylib.len + 1);
    const cmdsize_aligned: u32 = (cmdsize + 7) & ~@as(u32, 7);
    const header_size = @sizeOf(macho.mach_header_64);
    const total_len = header_size + cmdsize_aligned;

    const buf = try testing.allocator.alloc(u8, total_len);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    const header = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    header.* = .{ .magic = macho.MH_MAGIC_64, .ncmds = 1, .sizeofcmds = cmdsize_aligned };
    const dy = std.mem.bytesAsValue(macho.dylib_command, buf[header_size..][0..lc_size]);
    dy.* = .{
        .cmd = .LOAD_DYLIB,
        .cmdsize = cmdsize_aligned,
        .dylib = .{ .name = name_offset, .timestamp = 0, .current_version = 0, .compatibility_version = 0 },
    };
    @memcpy(buf[header_size + lc_size ..][0..dylib.len], dylib);

    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, buf);
}

test "runUnusedDeps keeps a dependency a still-installed keg's Mach-O links despite a missing edge" {
    const allocator = testing.allocator;

    const prefix = "/tmp/malt_unuseddeps_linkguard";
    std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(fs_test_io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/db");
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix ++ "/Cellar/jq/1.0/bin");

    // jq (direct) + oniguruma (dependency) installed, but NO dependency
    // edge — the corrupted-table state a pre-fix upgrade left behind.
    {
        var db = try sqlite.Database.open(prefix ++ "/db/malt.db");
        defer db.close();
        try schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason)
            \\VALUES ('jq', 'jq', '1.0', 'sha-jq', '/tmp/malt_unuseddeps_linkguard/Cellar/jq/1.0', 'direct'),
            \\       ('oniguruma', 'oniguruma', '6.9', 'sha-onig', '/tmp/malt_unuseddeps_linkguard/Cellar/oniguruma/6.9', 'dependency');
        );
    }

    // jq's binary hard-links opt/oniguruma — the linkage the DB table lost.
    try writeFakeDylibLinker(fs_test_io, prefix ++ "/Cellar/jq/1.0/bin/jq", "/opt/oniguruma/lib/libonig.5.dylib");

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    const ctx = AppCtx{ .io = fs_test_io, .environ = .empty };
    const result = try runUnusedDeps(&ctx, allocator, prefix, false);

    try testing.expectEqual(util.ScopeStatus.ok, result.status);
    // Nothing reaped: the only orphan is still linked by jq's binary.
    try testing.expectEqual(@as(u32, 0), result.removed);

    var db = try sqlite.Database.open(prefix ++ "/db/malt.db");
    defer db.close();
    var stmt = try db.prepare("SELECT COUNT(*) FROM kegs WHERE name = 'oniguruma';");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
}
