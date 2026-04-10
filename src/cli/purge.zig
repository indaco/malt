//! malt — purge command
//! Completely wipe a malt installation from disk.
//!
//! Deletes (under `{prefix}` by default):
//!   Cellar, Caskroom, store, opt, linked dirs (bin/lib/…), cache, tmp, db,
//!   and finally the prefix directory itself when empty.
//!
//! With `--remove-binary`, also unlinks `/usr/local/bin/mt` and
//! `/usr/local/bin/malt` after the rest of the install is gone.
//!
//! Safety model:
//!   * Interactive by default — requires typing the word `purge` to proceed.
//!   * Honours the global `--dry-run` flag and previews every target.
//!   * `--backup <path>` snapshots the installed package list to a manifest
//!     (in the same format as `mt backup --versions`) before any deletion.
//!   * Acquires `{prefix}/db/malt.lock` to serialise against other malt runs,
//!     and releases it before removing the db directory itself.
//!
//! Non-goals:
//!   * Per-package removal — use `mt uninstall <name>`.
//!   * Cache-only cleanup — use `mt cleanup`.
//!   * Orphan removal — use `mt autoremove` / `mt gc`.

const std = @import("std");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const lock_mod = @import("../db/lock.zig");
const backup_mod = @import("backup.zig");
const sqlite = @import("../db/sqlite.zig");
const help = @import("help.zig");

pub const Error = error{
    InvalidArgs,
    UserAborted,
    LockFailed,
    DatabaseError,
    OpenFileFailed,
    WriteFailed,
    OutOfMemory,
};

/// User-controllable options parsed from the purge subcommand's argv.
pub const Options = struct {
    keep_cache: bool = false,
    backup_path: ?[]const u8 = null,
    yes: bool = false,
    remove_binary: bool = false,
};

/// Category of a deletion target — used for grouping output and for the
/// lock-aware ordering in `execute`.
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

/// A single path scheduled for deletion.
pub const Target = struct {
    path: []const u8,
    category: Category,
};

/// Parse the purge-specific flags.  Global flags (`--dry-run`, `--quiet`,
/// etc.) are consumed by `main.zig` before dispatch and must NOT appear
/// here.  Unknown flags produce `Error.InvalidArgs`.
pub fn parseArgs(args: []const []const u8) Error!Options {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--keep-cache")) {
            opts.keep_cache = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            opts.yes = true;
        } else if (std.mem.eql(u8, arg, "--remove-binary")) {
            opts.remove_binary = true;
        } else if (std.mem.eql(u8, arg, "--backup") or std.mem.eql(u8, arg, "-b")) {
            if (i + 1 >= args.len) return Error.InvalidArgs;
            i += 1;
            opts.backup_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--backup=")) {
            opts.backup_path = arg["--backup=".len..];
        } else {
            return Error.InvalidArgs;
        }
    }
    return opts;
}

/// Build the ordered deletion plan for the given options.  Returned slice
/// and every `path` inside it are owned by the caller; free via `freePlan`.
///
/// Order is intentional: sub-trees first (linked dirs, Cellar, Caskroom,
/// store, cache, tmp), then the db directory (which holds the lock file —
/// execute() removes it after releasing the lock), then the prefix root.
pub fn buildPlan(
    allocator: std.mem.Allocator,
    opts: Options,
    prefix: []const u8,
    cache_dir: []const u8,
) Error![]Target {
    var list: std.ArrayList(Target) = .empty;
    errdefer freeList(allocator, &list);

    // Linked dirs first so dangling symlinks are cleaned before the Cellar
    // targets they point at.
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

/// Format a byte count as a human-readable string (e.g. "1.4 GB") into `buf`.
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

/// Best-effort recursive size of a directory (or single file) at `path`.
/// Returns 0 when the path cannot be opened — sizes are informational
/// only, so silent failures are preferable to aborting the dry-run.
fn pathSize(allocator: std.mem.Allocator, path: []const u8) u64 {
    // Non-directory fast path — stat and return.
    if (std.fs.cwd().statFile(path)) |st| {
        if (st.kind != .directory) return st.size;
    } else |_| {}

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var walker = dir.walk(allocator) catch return 0;
    defer walker.deinit();

    var total: u64 = 0;
    while (walker.next() catch null) |entry| {
        if (entry.kind == .file) {
            const s = entry.dir.statFile(entry.basename) catch continue;
            total += s.size;
        }
    }
    return total;
}

/// Write the warning banner.  Uses `output.warnPlain` so the repeated `⚠`
/// icon does not clutter every line of a multi-line warning block.
fn warnBanner() void {
    const rule = "────────────────────────────────────────────────────────────";
    output.warnPlain("{s}", .{rule});
    output.warnPlain("WARNING: this will permanently wipe your malt installation.", .{});
    output.warnPlain("{s}", .{rule});
}

/// Dump the currently-installed package list to `path` as a `mt backup`
/// manifest so the user can rebuild their environment with `mt restore`.
fn writeManifest(allocator: std.mem.Allocator, path: []const u8) Error!void {
    const prefix = atomic.maltPrefix();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return Error.DatabaseError;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    backup_mod.writeHeader(w) catch return Error.WriteFailed;

    // When there's no DB we still write a header-only manifest so that the
    // --backup path is honoured and the caller gets a predictable artefact.
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

    try writeBytesToPath(path, buf.items);
}

fn writeBytesToPath(path: []const u8, bytes: []const u8) Error!void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) {
            if (std.fs.path.isAbsolute(dir)) {
                std.fs.makeDirAbsolute(dir) catch {};
            } else {
                std.fs.cwd().makePath(dir) catch {};
            }
        }
    }
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return Error.OpenFileFailed
    else
        std.fs.cwd().createFile(path, .{ .truncate = true }) catch return Error.OpenFileFailed;
    defer file.close();
    file.writeAll(bytes) catch return Error.WriteFailed;
}

/// Try to remove `path`.  Returns `true` when the path is gone after the
/// call (either we removed it, or it never existed).
fn deleteTarget(path: []const u8) bool {
    std.fs.deleteTreeAbsolute(path) catch |e| switch (e) {
        error.FileNotFound => return true,
        else => {
            output.warn("could not remove {s}", .{path});
            return false;
        },
    };
    return true;
}

fn deletePrefixRoot(path: []const u8) bool {
    std.fs.deleteDirAbsolute(path) catch |e| switch (e) {
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

fn verify(plan: []const Target) void {
    var leaks: usize = 0;
    for (plan) |t| {
        if (t.category == .prefix_root) continue; // allowed to remain
        std.fs.accessAbsolute(t.path, .{}) catch continue;
        output.warn("verification: {s} still present", .{t.path});
        leaks += 1;
    }
    if (leaks == 0) {
        output.info("verification: all targeted paths are gone", .{});
    }
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "purge")) return;

    const opts = parseArgs(args) catch {
        output.err("invalid arguments — run `mt purge --help` for usage", .{});
        return Error.InvalidArgs;
    };

    const dry_run = output.isDryRun();
    const prefix = atomic.maltPrefix();
    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("failed to determine cache directory", .{});
        return Error.OpenFileFailed;
    };
    defer allocator.free(cache_dir);

    // ── Banner + target preview ──────────────────────────────────────────
    // Visual hierarchy:
    //   banner  → yellow (the alarm)
    //   context → dim    (prefix/cache/flags — supporting info)
    //   rows    → plain  (the paths you need to actually read)
    //   total   → bold   (the headline number)
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

    // ── Backup manifest ──────────────────────────────────────────────────
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

    // ── Confirmation gate ────────────────────────────────────────────────
    if (!opts.yes) {
        const confirmed = output.confirmTyped(
            "purge",
            "Type `purge` to continue (anything else aborts): ",
        );
        if (!confirmed) {
            output.info("aborted", .{});
            return Error.UserAborted;
        }
    }

    // ── Acquire lock (best-effort — absent db dir means nothing to race)
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk_maybe: ?lock_mod.LockFile = lock_mod.LockFile.acquire(lock_path, 30_000) catch null;

    // ── Deletions ────────────────────────────────────────────────────────
    var removed: usize = 0;
    var skipped: usize = 0;
    var db_idx: ?usize = null;
    var prefix_idx: ?usize = null;

    for (plan, 0..) |t, idx| {
        switch (t.category) {
            .db => {
                db_idx = idx;
                continue; // deferred until after lock release
            },
            .prefix_root => {
                prefix_idx = idx;
                continue; // deferred until last
            },
            else => {},
        }
        if (deleteTarget(t.path)) removed += 1 else skipped += 1;
    }

    // Release the lock before removing its parent directory.
    if (lk_maybe) |*lk| lk.release();

    if (db_idx) |idx| {
        if (deleteTarget(plan[idx].path)) removed += 1 else skipped += 1;
    }

    if (prefix_idx) |idx| {
        if (deletePrefixRoot(plan[idx].path)) removed += 1 else skipped += 1;
    }

    verify(plan);

    var sum_buf: [128]u8 = undefined;
    const sum = std.fmt.bufPrint(&sum_buf, "removed {d} target(s), skipped {d}", .{ removed, skipped }) catch "";
    output.success("{s}", .{sum});
}
