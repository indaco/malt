//! malt — purge command
//! Unified housekeeping + nuclear-wipe command.  A scope flag selects
//! what to remove; without one, the command refuses to run.
//!
//! Scopes (one or more required):
//!   --store-orphans  Refcount-0 blobs in {prefix}/store
//!   --unused-deps    Indirect-install kegs no other package needs
//!   --cache[=DAYS]   Cache files older than DAYS (default 30)
//!   --downloads      Wipe {cache}/downloads entirely
//!   --stale-casks    Cask cache + Caskroom entries for uninstalled casks
//!   --old-versions   Non-latest versions in {prefix}/Cellar
//!   --housekeeping   = --store-orphans --unused-deps --cache --stale-casks
//!   --wipe           Nuclear: remove every malt artefact from disk
//!
//! Shared flags:
//!   --dry-run, -n        Preview only (also recognised as the global flag)
//!   --yes, -y            Skip every typed confirmation prompt
//!   --quiet, -q          Suppress per-item output
//!   --backup, -b PATH    Write a `mt restore`-compatible manifest first
//!
//! --wipe-only flags:
//!   --keep-cache         Do not remove the cache directory
//!   --remove-binary      Also unlink /usr/local/bin/{mt,malt}
//!
//! Confirmation gates (skippable with --yes):
//!   --wipe          → type "purge"
//!   --downloads     → type "downloads"
//!   --old-versions  → type "old-versions"
//!
//! Non-goals:
//!   * Per-package removal — use `mt uninstall <name>`.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const io_mod = @import("../ui/io.zig");
const lock_mod = @import("../db/lock.zig");
const backup_mod = @import("backup.zig");
const store_mod = @import("../core/store.zig");
const deps_mod = @import("../core/deps.zig");
const linker_mod = @import("../core/linker.zig");
const cellar_mod = @import("../core/cellar.zig");
const help = @import("help.zig");

pub const Error = error{
    InvalidArgs,
    NoScope,
    UserAborted,
    LockFailed,
    DatabaseError,
    OpenFileFailed,
    WriteFailed,
    OutOfMemory,
};

const default_cache_days: i64 = 30;

/// Bitfield of selected scopes.  At least one must be set or `execute`
/// errors with `NoScope`.  `wipe` is mutually exclusive with the others.
pub const Scope = struct {
    store_orphans: bool = false,
    unused_deps: bool = false,
    cache: bool = false,
    downloads: bool = false,
    stale_casks: bool = false,
    old_versions: bool = false,
    wipe: bool = false,

    pub fn isEmpty(self: Scope) bool {
        return !(self.store_orphans or self.unused_deps or self.cache or
            self.downloads or self.stale_casks or self.old_versions or self.wipe);
    }

    pub fn anyNonWipe(self: Scope) bool {
        return self.store_orphans or self.unused_deps or self.cache or
            self.downloads or self.stale_casks or self.old_versions;
    }
};

/// User-controllable options parsed from the purge subcommand's argv.
pub const Options = struct {
    scope: Scope = .{},
    cache_days: i64 = default_cache_days,
    yes: bool = false,
    backup_path: ?[]const u8 = null,
    // --wipe-only:
    keep_cache: bool = false,
    remove_binary: bool = false,
};

/// Category of a deletion target — used by buildPlan/wipe.
pub const Category = enum {
    linked_dir, // {prefix}/bin, sbin, lib, include, share, etc
    opt, // {prefix}/opt
    cellar, // {prefix}/Cellar
    caskroom, // {prefix}/Caskroom
    store, // {prefix}/store
    cache, // {prefix}/cache (or $MALT_CACHE)
    tmp, // {prefix}/tmp
    db, // {prefix}/db — removed AFTER the lock is released
    prefix_root, // {prefix} itself — only removed if empty
    binary, // /usr/local/bin/{mt,malt} — opt-in via --remove-binary

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .linked_dir => "linked",
            .opt => "opt",
            .cellar => "Cellar",
            .caskroom => "Caskroom",
            .store => "store",
            .cache => "cache",
            .tmp => "tmp",
            .db => "db",
            .prefix_root => "prefix",
            .binary => "binary",
        };
    }
};

pub const Target = struct {
    path: []const u8,
    category: Category,
};

// ── Argument parsing ────────────────────────────────────────────────────────

pub fn parseArgs(args: []const []const u8) Error!Options {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Scope flags
        if (std.mem.eql(u8, arg, "--store-orphans")) {
            opts.scope.store_orphans = true;
        } else if (std.mem.eql(u8, arg, "--unused-deps")) {
            opts.scope.unused_deps = true;
        } else if (std.mem.eql(u8, arg, "--cache")) {
            opts.scope.cache = true;
        } else if (std.mem.startsWith(u8, arg, "--cache=")) {
            opts.scope.cache = true;
            opts.cache_days = std.fmt.parseInt(i64, arg["--cache=".len..], 10) catch
                return Error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--downloads")) {
            opts.scope.downloads = true;
        } else if (std.mem.eql(u8, arg, "--stale-casks")) {
            opts.scope.stale_casks = true;
        } else if (std.mem.eql(u8, arg, "--old-versions")) {
            opts.scope.old_versions = true;
        } else if (std.mem.eql(u8, arg, "--housekeeping")) {
            opts.scope.store_orphans = true;
            opts.scope.unused_deps = true;
            opts.scope.cache = true;
            opts.scope.stale_casks = true;
        } else if (std.mem.eql(u8, arg, "--wipe")) {
            opts.scope.wipe = true;
        }

        // Shared flags
        else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            opts.yes = true;
        } else if (std.mem.eql(u8, arg, "--backup") or std.mem.eql(u8, arg, "-b")) {
            if (i + 1 >= args.len) return Error.InvalidArgs;
            i += 1;
            opts.backup_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--backup=")) {
            opts.backup_path = arg["--backup=".len..];
        }

        // --wipe-only flags
        else if (std.mem.eql(u8, arg, "--keep-cache")) {
            opts.keep_cache = true;
        } else if (std.mem.eql(u8, arg, "--remove-binary")) {
            opts.remove_binary = true;
        }

        // Anything else is invalid (positionals included)
        else {
            return Error.InvalidArgs;
        }
    }

    if (opts.scope.wipe and opts.scope.anyNonWipe()) return Error.InvalidArgs;
    return opts;
}

// ── Wipe plan builders (unchanged surface for tests) ─────────────────────────

pub fn buildPlan(
    allocator: std.mem.Allocator,
    opts: Options,
    prefix: []const u8,
    cache_dir: []const u8,
) Error![]Target {
    var list: std.ArrayList(Target) = .empty;
    errdefer freeList(allocator, &list);

    const linked = [_][]const u8{ "bin", "sbin", "lib", "include", "share", "etc" };
    for (linked) |name| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name }) catch return Error.OutOfMemory;
        list.append(allocator, .{ .path = path, .category = .linked_dir }) catch return Error.OutOfMemory;
    }

    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/opt", .{prefix}) catch return Error.OutOfMemory,
        .category = .opt,
    }) catch return Error.OutOfMemory;
    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/Cellar", .{prefix}) catch return Error.OutOfMemory,
        .category = .cellar,
    }) catch return Error.OutOfMemory;
    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/Caskroom", .{prefix}) catch return Error.OutOfMemory,
        .category = .caskroom,
    }) catch return Error.OutOfMemory;
    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/store", .{prefix}) catch return Error.OutOfMemory,
        .category = .store,
    }) catch return Error.OutOfMemory;

    if (!opts.keep_cache) {
        const dup = allocator.dupe(u8, cache_dir) catch return Error.OutOfMemory;
        list.append(allocator, .{ .path = dup, .category = .cache }) catch return Error.OutOfMemory;
    }

    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/tmp", .{prefix}) catch return Error.OutOfMemory,
        .category = .tmp,
    }) catch return Error.OutOfMemory;
    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/db", .{prefix}) catch return Error.OutOfMemory,
        .category = .db,
    }) catch return Error.OutOfMemory;
    list.append(allocator, .{
        .path = allocator.dupe(u8, prefix) catch return Error.OutOfMemory,
        .category = .prefix_root,
    }) catch return Error.OutOfMemory;

    if (opts.remove_binary) {
        const bin_paths = [_][]const u8{ "/usr/local/bin/mt", "/usr/local/bin/malt" };
        for (bin_paths) |p| {
            const dup = allocator.dupe(u8, p) catch return Error.OutOfMemory;
            list.append(allocator, .{ .path = dup, .category = .binary }) catch return Error.OutOfMemory;
        }
    }

    return list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

pub fn freePlan(allocator: std.mem.Allocator, plan: []const Target) void {
    for (plan) |t| allocator.free(t.path);
    allocator.free(plan);
}

fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList(Target)) void {
    for (list.items) |t| allocator.free(t.path);
    list.deinit(allocator);
}

pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) {
        value /= 1024.0;
        unit += 1;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

fn pathSize(allocator: std.mem.Allocator, path: []const u8) u64 {
    if (fs_compat.cwd().statFile(path)) |st| {
        if (st.kind != .directory) return st.size;
    } else |_| {}

    var dir = fs_compat.openDirAbsolute(path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var walker = dir.walk(allocator) catch return 0;
    defer walker.deinit();

    var total: u64 = 0;
    while (walker.next() catch null) |entry| {
        if (entry.kind == .file) {
            const s = std.Io.Dir.statFile(entry.dir, io_mod.ctx(), entry.basename, .{}) catch continue;
            total += s.size;
        }
    }
    return total;
}

// ── Helpers shared by tier runners ───────────────────────────────────────────

const TierResult = struct {
    removed: u32 = 0,
    bytes: u64 = 0,
};

fn openDb(prefix: []const u8) ?sqlite.Database {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return null;
    return sqlite.Database.open(db_path) catch null;
}

fn confirmScope(yes: bool, expected: []const u8, scope_label: []const u8) Error!void {
    if (yes) return;
    var prompt_buf: [128]u8 = undefined;
    const prompt = std.fmt.bufPrint(
        &prompt_buf,
        "Type `{s}` to confirm {s} (anything else aborts): ",
        .{ expected, scope_label },
    ) catch "Type the scope name to confirm: ";
    if (!output.confirmTyped(expected, prompt)) {
        output.info("aborted", .{});
        return Error.UserAborted;
    }
}

fn writeStderr(s: []const u8) void {
    io_mod.stderrWriteAll(s);
}

// ── Tier: --store-orphans (was `gc`) ────────────────────────────────────────

fn runStoreOrphans(allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};

    var db = openDb(prefix) orelse {
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
        writeStderr("  ");
        writeStderr(sha);
        writeStderr("\n");
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

fn runUnusedDeps(allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};

    var db = openDb(prefix) orelse {
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
            writeStderr("  ");
            writeStderr(name);
            writeStderr("\n");
        }
        result.removed = @intCast(orphans.len);
        return result;
    }

    output.info("unused-deps: removing {d} package(s):", .{orphans.len});

    var linker = linker_mod.Linker.init(allocator, &db, prefix);
    var store = store_mod.Store.init(allocator, &db, prefix);

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
                if (parent_path.len > 0) fs_compat.deleteDirAbsolute(parent_path) catch {};
            }
            if (sha_ptr) |s| {
                store.decrementRef(std.mem.sliceTo(s, 0)) catch {};
            }
            var del = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch continue;
            defer del.finalize();
            del.bindInt(1, keg_id) catch continue;
            _ = del.step() catch {};

            writeStderr("  ");
            writeStderr(name);
            writeStderr("\n");
            result.removed += 1;
        }
    }
    return result;
}

// ── Tier: --cache[=DAYS] (was `cleanup --prune=`) ───────────────────────────

fn runCache(allocator: std.mem.Allocator, cache_dir: []const u8, max_age_days: i64, dry_run: bool) !TierResult {
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

fn runDownloads(allocator: std.mem.Allocator, cache_dir: []const u8, dry_run: bool) !TierResult {
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

fn runStaleCasks(allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
    var result: TierResult = .{};

    var db = openDb(prefix) orelse {
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

fn runOldVersions(allocator: std.mem.Allocator, prefix: []const u8, dry_run: bool) !TierResult {
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

        // Find the newest version by mtime — that's the keeper.  Semver
        // sorting would be more correct but is materially harder to get
        // right across the long tail of upstream version strings.
        var newest_idx: usize = 0;
        for (versions.items, 0..) |v, idx| {
            if (v.mtime > versions.items[newest_idx].mtime) newest_idx = idx;
        }

        for (versions.items, 0..) |v, idx| {
            if (idx == newest_idx) continue;
            var path_buf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&path_buf, "{s}/Cellar/{s}/{s}", .{ prefix, formula_entry.name, v.name }) catch continue;
            const sz = pathSize(allocator, full);
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

// ── Wipe path (existing nuclear behaviour) ──────────────────────────────────

fn warnBanner() void {
    const rule = "────────────────────────────────────────────────────────────";
    output.warnPlain("{s}", .{rule});
    output.warnPlain("WARNING: this will permanently wipe your malt installation.", .{});
    output.warnPlain("{s}", .{rule});
}

fn writeManifest(allocator: std.mem.Allocator, path: []const u8) Error!void {
    const prefix = atomic.maltPrefix();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return Error.DatabaseError;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    backup_mod.writeHeader(w) catch return Error.WriteFailed;

    if (sqlite.Database.open(db_path)) |*db_val| {
        var db = db_val.*;
        defer db.close();

        var fstmt = db.prepare(
            "SELECT name, version FROM kegs WHERE install_reason = 'direct' ORDER BY name;",
        ) catch null;
        if (fstmt) |*s| {
            defer s.finalize();
            while (s.step() catch false) {
                const name_ptr = s.columnText(0) orelse continue;
                const ver_ptr = s.columnText(1);
                const name = std.mem.sliceTo(name_ptr, 0);
                const version = if (ver_ptr) |p| std.mem.sliceTo(p, 0) else "";
                backup_mod.writeEntry(w, .formula, name, version, true) catch return Error.WriteFailed;
            }
        }

        var cstmt = db.prepare("SELECT token, version FROM casks ORDER BY token;") catch null;
        if (cstmt) |*s| {
            defer s.finalize();
            while (s.step() catch false) {
                const name_ptr = s.columnText(0) orelse continue;
                const ver_ptr = s.columnText(1);
                const name = std.mem.sliceTo(name_ptr, 0);
                const version = if (ver_ptr) |p| std.mem.sliceTo(p, 0) else "";
                backup_mod.writeEntry(w, .cask, name, version, true) catch return Error.WriteFailed;
            }
        }
    } else |_| {}

    try writeBytesToPath(path, aw.written());
}

fn writeBytesToPath(path: []const u8, bytes: []const u8) Error!void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) {
            if (std.fs.path.isAbsolute(dir)) {
                fs_compat.makeDirAbsolute(dir) catch {};
            } else {
                fs_compat.cwd().makePath(dir) catch {};
            }
        }
    }
    const file = if (std.fs.path.isAbsolute(path))
        fs_compat.createFileAbsolute(path, .{ .truncate = true }) catch return Error.OpenFileFailed
    else
        fs_compat.cwd().createFile(path, .{ .truncate = true }) catch return Error.OpenFileFailed;
    defer file.close();
    file.writeAll(bytes) catch return Error.WriteFailed;
}

fn deleteTarget(path: []const u8) bool {
    fs_compat.deleteTreeAbsolute(path) catch {
        output.warn("could not remove {s}", .{path});
        return false;
    };
    return true;
}

fn deletePrefixRoot(path: []const u8) bool {
    fs_compat.deleteDirAbsolute(path) catch |e| switch (e) {
        error.FileNotFound => return true,
        error.DirNotEmpty => {
            output.info("prefix {s} not empty — leaving it in place", .{path});
            return false;
        },
        else => {
            output.warn("could not remove prefix {s}", .{path});
            return false;
        },
    };
    return true;
}

fn verifyWipe(plan: []const Target) void {
    var leaks: usize = 0;
    for (plan) |t| {
        if (t.category == .prefix_root) continue;
        fs_compat.accessAbsolute(t.path, .{}) catch continue;
        output.warn("verification: {s} still present", .{t.path});
        leaks += 1;
    }
    if (leaks == 0) {
        output.info("verification: all targeted paths are gone", .{});
    }
}

fn runWipe(allocator: std.mem.Allocator, opts: Options, prefix: []const u8, cache_dir: []const u8, dry_run: bool) !void {
    warnBanner();
    output.dimPlain("prefix:  {s}", .{prefix});
    output.dimPlain("cache:   {s}", .{cache_dir});
    if (opts.keep_cache) output.dimPlain("keep-cache: on", .{});
    if (opts.remove_binary) output.dimPlain("remove-binary: on (/usr/local/bin/{{mt,malt}})", .{});

    const plan = try buildPlan(allocator, opts, prefix, cache_dir);
    defer freePlan(allocator, plan);

    var total_bytes: u64 = 0;
    for (plan) |t| {
        const size = pathSize(allocator, t.path);
        total_bytes += size;
        var sz_buf: [32]u8 = undefined;
        const sz = formatBytes(size, &sz_buf);
        output.plain("  [{s:<8}] {s} ({s})", .{ t.category.label(), t.path, sz });
    }
    {
        var buf: [64]u8 = undefined;
        const total_str = formatBytes(total_bytes, &buf);
        output.boldPlain("total: {s}", .{total_str});
    }

    if (opts.backup_path) |bp| {
        if (dry_run) {
            output.info("would write backup manifest to {s}", .{bp});
        } else {
            try writeManifest(allocator, bp);
            output.success("backup manifest written to {s}", .{bp});
        }
    }

    if (dry_run) {
        output.info("dry run — nothing was removed", .{});
        return;
    }

    try confirmScope(opts.yes, "purge", "wipe");

    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk_maybe: ?lock_mod.LockFile = lock_mod.LockFile.acquire(lock_path, 30_000) catch null;

    var removed: usize = 0;
    var skipped: usize = 0;
    var db_idx: ?usize = null;
    var prefix_idx: ?usize = null;

    for (plan, 0..) |t, idx| {
        switch (t.category) {
            .db => {
                db_idx = idx;
                continue;
            },
            .prefix_root => {
                prefix_idx = idx;
                continue;
            },
            else => {},
        }
        if (deleteTarget(t.path)) removed += 1 else skipped += 1;
    }

    if (lk_maybe) |*lk| lk.release();

    if (db_idx) |idx| {
        if (deleteTarget(plan[idx].path)) removed += 1 else skipped += 1;
    }
    if (prefix_idx) |idx| {
        if (deletePrefixRoot(plan[idx].path)) removed += 1 else skipped += 1;
    }

    verifyWipe(plan);

    var sum_buf: [128]u8 = undefined;
    const sum = std.fmt.bufPrint(&sum_buf, "removed {d} target(s), skipped {d}", .{ removed, skipped }) catch "";
    output.success("{s}", .{sum});
}

// ── Entry point ──────────────────────────────────────────────────────────────

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "purge")) return;

    const opts = parseArgs(args) catch {
        output.err("invalid arguments — run `mt purge --help` for usage", .{});
        return Error.InvalidArgs;
    };

    if (opts.scope.isEmpty()) {
        output.err("purge requires a scope flag — see `mt purge --help`", .{});
        output.dim("examples: mt purge --housekeeping  |  mt purge --store-orphans  |  mt purge --wipe", .{});
        return Error.NoScope;
    }

    const dry_run = output.isDryRun();
    const prefix = atomic.maltPrefix();
    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("failed to determine cache directory", .{});
        return Error.OpenFileFailed;
    };
    defer allocator.free(cache_dir);

    if (opts.scope.wipe) {
        try runWipe(allocator, opts, prefix, cache_dir, dry_run);
        return;
    }

    // Per-scope confirmations (only those that are destructive enough to
    // warrant a typed gate).  Skipped on --dry-run to keep previews silent.
    if (!dry_run) {
        if (opts.scope.downloads) try confirmScope(opts.yes, "downloads", "downloads scrub");
        if (opts.scope.old_versions) try confirmScope(opts.yes, "old-versions", "old-versions removal");
    }

    // Optional backup before any destructive scope runs.
    if (opts.backup_path) |bp| {
        if (dry_run) {
            output.info("would write backup manifest to {s}", .{bp});
        } else {
            try writeManifest(allocator, bp);
            output.success("backup manifest written to {s}", .{bp});
        }
    }

    // One shared lock for all non-wipe scopes.  Lock path may not exist
    // (fresh install with no DB) — that's fine, we proceed without.
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk_maybe: ?lock_mod.LockFile = lock_mod.LockFile.acquire(lock_path, 30_000) catch null;
    defer if (lk_maybe) |*lk| lk.release();

    var grand_total: TierResult = .{};

    // unused-deps must run before store-orphans: removing a keg decrements
    // its store ref to 0, and those fresh orphans only get swept on the
    // second pass.
    if (opts.scope.unused_deps) {
        const r = try runUnusedDeps(allocator, prefix, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }
    if (opts.scope.store_orphans) {
        const r = try runStoreOrphans(allocator, prefix, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }
    if (opts.scope.cache) {
        const r = try runCache(allocator, cache_dir, opts.cache_days, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }
    if (opts.scope.downloads) {
        const r = try runDownloads(allocator, cache_dir, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }
    if (opts.scope.stale_casks) {
        const r = try runStaleCasks(allocator, prefix, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }
    if (opts.scope.old_versions) {
        const r = try runOldVersions(allocator, prefix, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }

    var sz_buf: [32]u8 = undefined;
    const sz = formatBytes(grand_total.bytes, &sz_buf);
    if (dry_run) {
        output.info("dry run: would remove {d} item(s), ~{s}", .{ grand_total.removed, sz });
    } else {
        output.success("removed {d} item(s), freed ~{s}", .{ grand_total.removed, sz });
    }
}
