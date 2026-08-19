//! malt — rollback command
//! Revert a formula to its previous version using existing store entries.

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const lock_mod = @import("../db/lock.zig");
const lock_report = @import("lock_report.zig");
const cellar = @import("../core/cellar.zig");
const cask_mod = @import("../core/cask.zig");
const linker_mod = @import("../core/linker.zig");
const store_mod = @import("../core/store.zig");
const atomic = @import("../fs/atomic.zig");
const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");
const install_mod = @import("install.zig");
const formula_mod = @import("../core/formula.zig");

/// `error.Aborted` is returned on every user-facing failure. The caller has
/// already emitted a message via `output.err`; main.zig catches it and exits
/// non-zero without printing a stack trace.
const ParsedArgs = struct {
    name: ?[]const u8 = null,
    dry_run: bool = false,
    list_mode: bool = false,
    to_version: ?[]const u8 = null,
};

/// Parse rollback argv. The first non-flag positional is the package name;
/// flags (`--list`, `--dry-run`, `--to <ver>` / `--to=<ver>`) can appear in
/// any order. Returns `error.Aborted` for unknown flags or a missing value
/// after `--to` so the dispatcher surfaces the same exit code as other
/// usage errors.
fn parseArgs(args: []const []const u8) error{Aborted}!ParsedArgs {
    var p: ParsedArgs = .{ .dry_run = output.isDryRun() };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--dry-run")) {
            p.dry_run = true;
        } else if (std.mem.eql(u8, a, "--list")) {
            p.list_mode = true;
        } else if (std.mem.eql(u8, a, "--to")) {
            if (i + 1 >= args.len) {
                output.err("--to requires a version argument", .{});
                return error.Aborted;
            }
            i += 1;
            p.to_version = args[i];
        } else if (std.mem.startsWith(u8, a, "--to=")) {
            p.to_version = a["--to=".len..];
        } else if (a.len > 0 and a[0] == '-') {
            output.err("Unknown flag: {s}", .{a});
            return error.Aborted;
        } else if (p.name == null) {
            p.name = a;
        }
    }
    return p;
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "rollback")) return;

    const parsed = try parseArgs(args);
    const name = parsed.name orelse {
        output.err("Usage: mt rollback <package> [--list] [--to <version>]", .{});
        return error.Aborted;
    };
    const dry_run = parsed.dry_run;

    const prefix = atomic.maltPrefixOrAbort();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return error.Aborted;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
    schema.initSchema(&db) catch return error.Aborted;

    // Find current installed version
    var cur_stmt = db.prepare(
        "SELECT id, version, revision, store_sha256, cellar_path, bin_isolated FROM kegs WHERE name = ?1 ORDER BY installed_at DESC LIMIT 1;",
    ) catch return error.Aborted;
    defer cur_stmt.finalize();
    cur_stmt.bindText(1, name) catch return error.Aborted;

    if (!(cur_stmt.step() catch false)) {
        // Cask path: not a keg, but the same token may name an
        // installed cask. The cask listing and reinstall flow live
        // alongside the keg flow so the user-facing `--list` / `--to`
        // / default behaviours are consistent across package types.
        if (isCaskInstalled(&db, name)) {
            return dispatchCask(ctx, allocator, &db, name, parsed);
        }
        output.err("{s} is not installed", .{name});
        return error.Aborted;
    }

    const current_id = cur_stmt.columnInt(0);
    const current_ver_ptr = cur_stmt.columnText(1);
    const current_ver = if (current_ver_ptr) |v| std.mem.sliceTo(v, 0) else "unknown";
    const current_revision = cur_stmt.columnInt(2);

    // Kept so a failed swap can rebuild the current version's symlinks:
    // the filesystem half of the swap isn't covered by the DB transaction.
    const current_cellar_ptr = cur_stmt.columnText(4);
    const current_cellar_path = if (current_cellar_ptr) |c| std.mem.sliceTo(c, 0) else "";
    const current_bin_isolated = cur_stmt.columnInt(5) != 0;

    // pkg_version is what the on-disk Cellar / store dir is named after,
    // so the store-scan below must compare against this — not the bare
    // upstream `version` — to correctly skip a current revision-bumped
    // keg (e.g. version="1.9.2", revision=2 → label "1.9.2_2").
    var current_pkgver_buf: [128]u8 = undefined;
    const current_pkg_version = formula_mod.pkgVersion(&current_pkgver_buf, current_ver, current_revision) catch current_ver;

    // `--to <current>` is an idempotent no-op: the user is asking to
    // land on the version they're already on, so do nothing rather than
    // surface "not in the store" against a listing that omits the
    // current entry by design.
    if (parsed.to_version) |req| {
        if (std.mem.eql(u8, req, current_pkg_version) or std.mem.eql(u8, req, current_ver)) {
            output.info("{s} is already at {s}", .{ name, current_ver });
            return;
        }
    }

    var entries = collectEntries(ctx.io, allocator, prefix, name, current_pkg_version) catch |e| switch (e) {
        CollectError.StoreUnreadable => {
            output.err("Cannot read store directory", .{});
            return error.Aborted;
        },
        CollectError.OutOfMemory => return error.Aborted,
    };
    defer freeEntries(allocator, &entries);

    if (parsed.list_mode) {
        return printListing(allocator, name, entries.items);
    }

    if (entries.items.len == 0) {
        output.err("No previous version found for {s} in the store", .{name});
        output.info("The store only contains the current version ({s})", .{current_ver});
        return error.Aborted;
    }

    const target_idx = selectTargetIndex(entries.items, parsed.to_version) catch {
        // --to NotFound — refuse and print the listing so the user can pick.
        output.err("{s} {s} is not in the store", .{ name, parsed.to_version orelse "" });
        try printListing(allocator, name, entries.items);
        return error.Aborted;
    };
    const target = entries.items[target_idx];

    output.info("Rolling back {s}: {s} -> {s}", .{ name, current_ver, target.pkg_version });

    if (dry_run) {
        output.info("Dry run: would rollback {s} from {s} to {s}", .{ name, current_ver, target.pkg_version });
        return;
    }

    // Acquire lock
    var lock_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix}) catch return error.Aborted;
    var lk = lock_mod.LockFile.acquire(ctx.io, lock_path, 30000) catch |e| switch (e) {
        // The DB is already open here, so db/ exists — DirMissing can't occur.
        error.DirMissing => return error.Aborted,
        // Every other failure gets an accurate, actionable diagnostic
        // (permissions, contention, …) instead of a blanket message.
        else => {
            lock_report.reportAcquireFailure(e, prefix);
            return error.Aborted;
        },
    };
    defer lk.release(ctx.io);

    // No parsed formula here, and the DB rows describe the version being
    // rolled away from — so read the target's own shipped formula source.
    var ph_buf: [512]u8 = undefined;
    const placeholder = storeKegPlaceholder(
        ctx.io,
        allocator,
        &ph_buf,
        prefix,
        target.sha256,
        name,
        target.pkg_version,
    );

    // Materialize before touching the current install: store entries are
    // on-disk input, so a corrupt one must not cost the user a working
    // version. Nothing is destroyed yet, so failure needs no restore.
    const keg = cellar.materializeWithCellar(
        ctx.io,
        allocator,
        prefix,
        target.sha256,
        name,
        target.pkg_version,
        // Unchanged from the `materialize` wrapper this replaced.
        "",
        if (placeholder) |p| .{ .old = p.token, .new = p.value } else null,
    ) catch {
        output.err("Failed to materialize {s} {s} from store", .{ name, target.pkg_version });
        return error.Aborted;
    };
    defer allocator.free(keg.path);

    // Update DB: delete old record, insert new one. Capture the old
    // pin BEFORE the delete so the new row can inherit it — rolling
    // back a held formula must not silently clear the user's hold.
    const carried: Carried = .{
        .pinned = capturePinnedById(&db, current_id),
        .bin_isolated = current_bin_isolated,
    };

    var linker = linker_mod.Linker.init(ctx.io, allocator, &db, prefix);

    db.beginTransaction() catch return error.Aborted;

    const keg_id = swapKeg(&db, &linker, current_id, name, target, keg.path, carried) catch {
        db.rollback();
        restoreCurrentLinks(&linker, current_cellar_path, name, current_id, current_bin_isolated);
        cellar.remove(ctx.io, prefix, name, target.pkg_version) catch {};
        output.err("Failed to record rollback of {s} in the database", .{name});
        return error.Aborted;
    };

    db.commit() catch {
        // Drop the new symlinks first: the filesystem isn't transactional,
        // so rolling back the DB alone would strand them.
        linker.unlink(keg_id) catch {};
        db.rollback();
        restoreCurrentLinks(&linker, current_cellar_path, name, current_id, current_bin_isolated);
        cellar.remove(ctx.io, prefix, name, target.pkg_version) catch {};
        output.err("Failed to commit rollback of {s}", .{name});
        return error.Aborted;
    };

    // Only now is the previous version expendable. pkg_version-aware so a
    // revision-bumped current keg dir (e.g. "1.9.2_2") doesn't linger.
    removeCurrentCellarDir(ctx.io, prefix, name, current_ver, current_revision) catch {
        output.warn("Could not remove cellar entry for {s} {s}", .{ name, current_pkg_version });
    };

    // opt/ is a plain symlink, so it stays outside the transaction.
    linker.linkOpt(name, target.pkg_version) catch {
        output.warn("Could not create opt link for {s}", .{name});
    };

    output.info("{s} rolled back to {s}", .{ name, target.pkg_version });
}

/// Swap the current keg for `target` inside the caller's transaction.
/// `unlink` deletes `links` rows, so all three steps have to share one
/// transaction or a mid-flight failure strands them.
fn swapKeg(
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    current_id: i64,
    name: []const u8,
    target: Entry,
    keg_path: []const u8,
    carried: Carried,
) !i64 {
    try linker.unlink(current_id);
    // target.pkg_version carries the on-disk pkg_version label (the store
    // dir name), so replaceKegRow can split it back into version +
    // revision and persist the rolled-back keg's true revision.
    const keg_id = try replaceKegRow(db, current_id, name, target.pkg_version, target.sha256, keg_path, carried);
    try linker.link(keg_path, name, keg_id, carried.bin_isolated);
    return keg_id;
}

/// Rebuild the symlinks of the version we were rolling away from. The DB
/// transaction restores the `links` rows; the filesystem needs replaying.
fn restoreCurrentLinks(
    linker: *linker_mod.Linker,
    cellar_path: []const u8,
    name: []const u8,
    keg_id: i64,
    bin_isolated: bool,
) void {
    if (cellar_path.len == 0) return;
    linker.link(cellar_path, name, keg_id, bin_isolated) catch {
        output.err("CRITICAL: could not restore symlinks for {s} - run: mt link {s}", .{ name, name });
    };
}

/// Handle the cask side of `mt rollback`. Mirrors the keg flow:
///   - `--list` prints retained versions (excluding current).
///   - `--to <ver>` and the default selection refuse with a clear
///     diagnostic until per-version artefact retention lands in the
///     install path; `--list` is fully wired in the meantime.
fn dispatchCask(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    token: []const u8,
    parsed: ParsedArgs,
) !void {
    const cur_ver_opt = currentCaskVersion(allocator, db, token);
    defer if (cur_ver_opt) |v| allocator.free(v);

    // `--to <current>`: idempotent no-op, same UX as the keg path.
    if (parsed.to_version) |req| {
        if (cur_ver_opt) |cv| {
            if (std.mem.eql(u8, req, cv)) {
                output.info("{s} is already at {s}", .{ token, cv });
                return;
            }
        }
    }

    var entries = try collectCaskEntries(allocator, db, token, cur_ver_opt);
    defer freeEntries(allocator, &entries);

    if (parsed.list_mode) {
        return printListing(allocator, token, entries.items);
    }

    if (entries.items.len == 0) {
        output.err("No previous version found for {s}", .{token});
        if (cur_ver_opt) |cv| {
            output.info("the cask history only contains the current version ({s})", .{cv});
        }
        output.info("cask versions accumulate on future installs; upgrade {s} to populate history", .{token});
        return error.Aborted;
    }

    // Resolve the target version: `--to <ver>` or default (newest).
    const target_pkg_version = blk: {
        if (parsed.to_version) |req| {
            const idx = selectTargetIndex(entries.items, req) catch {
                output.err("{s} {s} is not in the cask history", .{ token, req });
                try printListing(allocator, token, entries.items);
                return error.Aborted;
            };
            break :blk entries.items[idx].pkg_version;
        }
        break :blk entries.items[0].pkg_version;
    };

    const cur_ver_str = cur_ver_opt orelse "unknown";
    output.info("Rolling back {s}: {s} -> {s}", .{ token, cur_ver_str, target_pkg_version });

    if (parsed.dry_run) {
        output.info("Dry run: would reinstall {s} {s} from cask history", .{ token, target_pkg_version });
        return;
    }

    // A PKG-cask rollback re-runs `sudo installer -target /`. Gate it before the
    // lock + reinstall so a refusal off a TTY changes nothing on disk.
    const target_is_pkg = blk: {
        var row = (cask_mod.lookupCaskVersion(allocator, db, token, target_pkg_version) catch null) orelse break :blk false;
        defer row.deinit(allocator);
        break :blk cask_mod.artifactTypeFromTag(row.artifact_type) == .pkg;
    };
    if (target_is_pkg) {
        output.warn("{s} is a PKG cask and requires sudo to install via macOS Installer.", .{token});
        if (!install_mod.confirmPkgSudo(token)) return error.Aborted;
    }

    const prefix = atomic.maltPrefixOrAbort();

    // Serialize the uninstall+reinstall on the prefix lock, exactly like the
    // keg path — acquired only after the read-only early returns so --list and
    // --dry-run stay lock-free.
    var lock_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix}) catch return error.Aborted;
    var lk = lock_mod.LockFile.acquire(ctx.io, lock_path, 30000) catch |e| switch (e) {
        // The DB is already open here, so db/ exists — DirMissing can't occur.
        error.DirMissing => return error.Aborted,
        // Every other failure gets an accurate, actionable diagnostic
        // (permissions, contention, …) instead of a blanket message.
        else => {
            lock_report.reportAcquireFailure(e, prefix);
            return error.Aborted;
        },
    };
    defer lk.release(ctx.io);

    var installer = cask_mod.CaskInstaller.init(ctx.io, ctx.environ, allocator, db, prefix);
    installer.offline = ctx.offline;
    installer.reinstallFromHistory(token, target_pkg_version) catch |e| {
        output.err("failed to reinstall {s} {s} ({s})", .{ token, target_pkg_version, @errorName(e) });
        return error.Aborted;
    };
    output.info("{s} rolled back to {s}", .{ token, target_pkg_version });
}

/// Best-effort lookup: is `token` registered as an installed cask? Used to
/// split the rollback "not installed" diagnostic so a cask token doesn't
/// read as a missing package. Any SQL failure collapses to `false` — the
/// caller falls back to the original message rather than masking the
/// underlying error.
fn isCaskInstalled(db: *sqlite.Database, token: []const u8) bool {
    var stmt = db.prepare("SELECT 1 FROM casks WHERE token = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, token) catch return false;
    return stmt.step() catch false;
}

/// Read the currently-installed cask version for `token` so the rollback
/// listing can exclude it the same way the keg listing excludes the
/// current keg. Returns null when the cask is absent or unreadable.
/// Caller owns the returned slice and must `allocator.free` it.
pub fn currentCaskVersion(allocator: std.mem.Allocator, db: *sqlite.Database, token: []const u8) ?[]u8 {
    var stmt = db.prepare("SELECT version FROM casks WHERE token = ?1 LIMIT 1;") catch return null;
    defer stmt.finalize();
    stmt.bindText(1, token) catch return null;
    if (!(stmt.step() catch false)) return null;
    const ver_ptr = stmt.columnText(0) orelse return null;
    return allocator.dupe(u8, std.mem.sliceTo(ver_ptr, 0)) catch null;
}

/// Collect rollback candidates for a cask from the `cask_versions`
/// history table. `skip_version`, when non-null, drops the row matching
/// it (typically the currently-installed version). Result sorted
/// newest-first by `installed_at`. Caller owns the inner slices + list
/// and releases via `freeEntries`.
pub fn collectCaskEntries(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    token: []const u8,
    skip_version: ?[]const u8,
) CollectError!std.ArrayList(Entry) {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(allocator, &entries);

    var stmt = db.prepare(
        \\SELECT version, sha256, strftime('%s', installed_at) AS ts
        \\FROM cask_versions WHERE token = ?1
        \\ORDER BY installed_at DESC;
    ) catch return CollectError.StoreUnreadable;
    defer stmt.finalize();
    stmt.bindText(1, token) catch return CollectError.StoreUnreadable;

    while (stmt.step() catch false) {
        const ver_ptr = stmt.columnText(0) orelse continue;
        const ver_slice = std.mem.sliceTo(ver_ptr, 0);
        if (skip_version) |skip| {
            if (std.mem.eql(u8, ver_slice, skip)) continue;
        }

        // sha256 is nullable on the casks side; surface "" so the printer
        // doesn't emit a trailing parenthetical that looks like a bug.
        const sha_slice: []const u8 = if (stmt.columnText(1)) |s| std.mem.sliceTo(s, 0) else "";
        // strftime('%s', ...) returns text; parse → seconds → ns to fit
        // the keg-side Entry's `mtime_ns` field.
        const ts_secs: i128 = if (stmt.columnText(2)) |t| std.fmt.parseInt(i128, std.mem.sliceTo(t, 0), 10) catch 0 else 0;

        const ver_dup = allocator.dupe(u8, ver_slice) catch return CollectError.OutOfMemory;
        errdefer allocator.free(ver_dup);
        const sha_dup = allocator.dupe(u8, sha_slice) catch return CollectError.OutOfMemory;
        errdefer allocator.free(sha_dup);
        try entries.append(allocator, .{
            .sha256 = sha_dup,
            .pkg_version = ver_dup,
            .mtime_ns = ts_secs * std.time.ns_per_s,
        });
    }
    return entries;
}

/// Wipe the on-disk Cellar dir for a keg currently at `version`/`revision`.
/// The dir is named after the pkg_version label (e.g. "1.9.2_2"), so the
/// suffix has to be reconstructed here — handing `cellar.remove` the bare
/// upstream `version` would orphan a revision-bumped keg.
pub fn removeCurrentCellarDir(
    io: std.Io,
    prefix: []const u8,
    name: []const u8,
    version: []const u8,
    revision: i64,
) cellar.CellarError!void {
    var pkgver_buf: [128]u8 = undefined;
    const pkg_version = formula_mod.pkgVersion(&pkgver_buf, version, revision) catch version;
    return cellar.remove(io, prefix, name, pkg_version);
}

/// Returns the `pinned` flag of the keg row identified by `keg_id`, or
/// false if the row is missing or the read fails. Pub for tests; used
/// inside `execute` to snapshot the hold across a DELETE/INSERT swap.
pub fn capturePinnedById(db: *sqlite.Database, keg_id: i64) bool {
    var stmt = db.prepare("SELECT pinned FROM kegs WHERE id = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return false;
    if (!(stmt.step() catch false)) return false;
    return stmt.columnBool(0);
}

/// Columns that describe the user's intent rather than the version being
/// installed, so the row swap has to carry them across.
pub const Carried = struct {
    pinned: bool,
    bin_isolated: bool,
};

/// Swap the keg row identified by `old_keg_id` for a fresh row pointing
/// at `pkg_version` (the on-disk label, e.g. "1.9.2_2"). Splits the
/// label into `version` + `revision` so the new row reflects the
/// rolled-back keg's true revision instead of silently writing 0.
/// Returns the new keg row id. Caller owns the surrounding transaction.
pub fn replaceKegRow(
    db: *sqlite.Database,
    old_keg_id: i64,
    name: []const u8,
    pkg_version: []const u8,
    store_sha256: []const u8,
    cellar_path: []const u8,
    carried: Carried,
) !i64 {
    const parsed = formula_mod.parsePkgVersion(pkg_version);

    {
        var del = try db.prepare("DELETE FROM kegs WHERE id = ?1;");
        defer del.finalize();
        try del.bindInt(1, old_keg_id);
        _ = try del.step();
    }

    {
        var ins = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason, pinned, bin_isolated)
            \\VALUES (?1, ?1, ?2, ?3, ?4, ?5, 'direct', ?6, ?7);
        );
        defer ins.finalize();
        try ins.bindText(1, name);
        try ins.bindText(2, parsed.version);
        try ins.bindInt(3, parsed.revision);
        try ins.bindText(4, store_sha256);
        try ins.bindText(5, cellar_path);
        try ins.bindInt(6, @intFromBool(carried.pinned));
        try ins.bindInt(7, @intFromBool(carried.bin_isolated));
        _ = try ins.step();
    }

    var id_stmt = try db.prepare("SELECT last_insert_rowid();");
    defer id_stmt.finalize();
    if (!(try id_stmt.step())) return error.RecordFailed;
    return id_stmt.columnInt(0);
}

/// A single rolled-back-to candidate discovered in the malt store.
/// Slices are allocator-owned; `freeEntries` releases them.
pub const Entry = struct {
    sha256: []const u8,
    pkg_version: []const u8,
    mtime_ns: i128,
};

pub const CollectError = error{StoreUnreadable} || std.mem.Allocator.Error;

/// Scan `<prefix>/store/<sha>/<name>/<pkg_version>/` and collect every
/// rollback candidate for `name`. `skip_pkg_version`, when non-null,
/// drops the entry whose pkg_version matches it (typically the currently
/// installed version). Returned list is sorted newest-first by mtime.
/// Caller owns the inner slices and the list; release via `freeEntries`.
pub fn collectEntries(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    name: []const u8,
    skip_pkg_version: ?[]const u8,
) CollectError!std.ArrayList(Entry) {
    var store_buf: [512]u8 = undefined;
    const store_dir_path = std.fmt.bufPrint(&store_buf, "{s}/store", .{prefix}) catch
        return CollectError.StoreUnreadable;

    var store_dir = std.Io.Dir.openDirAbsolute(io, store_dir_path, .{ .iterate = true }) catch
        return CollectError.StoreUnreadable;
    defer store_dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(allocator, &entries);

    var iter = store_dir.iterate();
    while (iter.next(io) catch null) |sha_entry| {
        if (sha_entry.kind != .directory) continue;

        // Each <sha> may carry a <sha>/<name>/<pkg_version>/ pair; skip when the
        // package isn't represented here.
        var name_buf: [512]u8 = undefined;
        const name_path = std.fmt.bufPrint(&name_buf, "{s}/{s}/{s}", .{ store_dir_path, sha_entry.name, name }) catch continue;

        var name_dir = std.Io.Dir.openDirAbsolute(io, name_path, .{ .iterate = true }) catch continue;
        defer name_dir.close(io);

        var ver_iter = name_dir.iterate();
        while (ver_iter.next(io) catch null) |ver_entry| {
            if (ver_entry.kind != .directory) continue;
            if (skip_pkg_version) |skip| {
                if (std.mem.eql(u8, ver_entry.name, skip)) continue;
            }

            const stat = name_dir.statFile(io, ver_entry.name, .{}) catch continue;
            const sha_dup = allocator.dupe(u8, sha_entry.name) catch return CollectError.OutOfMemory;
            errdefer allocator.free(sha_dup);
            const ver_dup = allocator.dupe(u8, ver_entry.name) catch return CollectError.OutOfMemory;
            errdefer allocator.free(ver_dup);
            try entries.append(allocator, .{
                .sha256 = sha_dup,
                .pkg_version = ver_dup,
                .mtime_ns = stat.mtime.nanoseconds,
            });
        }
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn cmp(_: void, a: Entry, b: Entry) bool {
            return a.mtime_ns > b.mtime_ns;
        }
    }.cmp);
    return entries;
}

/// Flush `entries` to stdout in the format selected by `output.isJson()`.
/// Routes through `output.writeStdoutAll` so test captures see the bytes.
fn printListing(
    allocator: std.mem.Allocator,
    name: []const u8,
    entries: []const Entry,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    if (output.isJson()) {
        try writeListJson(&aw.writer, name, entries);
    } else {
        try writeListHuman(&aw.writer, name, entries, color.isColorEnabledFor(.stdout));
    }
    output.writeStdoutAll(aw.written());
}

/// Release every owned slice in `entries.items`, then deinit the list itself.
pub fn freeEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry)) void {
    for (entries.items) |e| {
        allocator.free(e.sha256);
        allocator.free(e.pkg_version);
    }
    entries.deinit(allocator);
}

pub const SelectError = error{NotFound};

/// Pick the rollback target. With `requested_version == null` returns the
/// newest entry (index 0 of a list pre-sorted newest-first). With a
/// requested version, returns the first entry whose `pkg_version`
/// matches exactly. `NotFound` covers both the empty-list-default case
/// and a requested version that is absent from the store.
pub fn selectTargetIndex(entries: []const Entry, requested_version: ?[]const u8) SelectError!usize {
    if (requested_version) |v| {
        for (entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.pkg_version, v)) return i;
        }
        return SelectError.NotFound;
    }
    if (entries.len == 0) return SelectError.NotFound;
    return 0;
}

/// `--list` human format: header + one bulleted row per entry, matching
/// the `mt list --versions` shape. Caller supplies entries already sorted
/// newest-first. With `colorize=false` the output stays plain ASCII (no
/// ANSI) so test golden checks are stable.
pub fn writeListHuman(
    w: *std.Io.Writer,
    name: []const u8,
    entries: []const Entry,
    colorize: bool,
) !void {
    try w.writeAll("Available rollback versions for ");
    if (colorize) try w.writeAll(color.Style.bold.code());
    try w.writeAll(name);
    if (colorize) try w.writeAll(color.Style.reset.code());
    if (entries.len == 0) {
        try w.writeAll(": none\n");
        return;
    }
    try w.writeAll(" (newest first):\n");

    var scratch: [32]u8 = undefined;
    for (entries) |e| {
        // Bullet prefix mirrors `mt list`'s row marker for visual parity.
        if (colorize) try w.writeAll(color.SemanticStyle.info.code());
        try w.writeAll("  ▸ ");
        if (colorize) try w.writeAll(color.Style.reset.code());

        try w.writeAll(e.pkg_version);

        if (colorize) try w.writeAll(color.SemanticStyle.detail.code());
        try w.writeAll(" (");
        try w.writeAll(e.sha256);
        try w.writeAll(")  ");
        const iso = try formatIso8601(&scratch, e.mtime_ns);
        try w.writeAll(iso);
        if (colorize) try w.writeAll(color.Style.reset.code());
        try w.writeAll("\n");
    }
}

/// Render `mtime_ns` (unix nanoseconds) as `YYYY-MM-DDTHH:MM:SSZ` into `buf`.
/// Negative values clamp to the epoch so a missing/bogus mtime renders as
/// `1970-01-01T00:00:00Z` instead of corrupting the listing.
fn formatIso8601(buf: []u8, mtime_ns: i128) ![]const u8 {
    const secs: i64 = @intCast(@max(@divTrunc(mtime_ns, std.time.ns_per_s), 0));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_of_month: u16 = @as(u16, month_day.day_index) + 1;
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            day_of_month,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

/// `--list` JSON shape: `{"name":"<pkg>","entries":[{"sha256":..,"version":..,"mtime":..},...]}`.
/// `mtime` is unix seconds (integer) so consumers don't have to parse ns precision.
pub fn writeListJson(w: *std.Io.Writer, name: []const u8, entries: []const Entry) !void {
    try w.writeAll("{\"name\":");
    try output.jsonStr(w, name);
    try w.writeAll(",\"entries\":");
    try writeEntriesJsonArray(w, entries);
    try w.writeAll("}\n");
}

/// Just the `[{sha256,version,mtime}, ...]` array. Shared so `mt info`
/// can splice the rollback-list shape into its installed-package JSON
/// without rewriting the encoder — one source of truth for downstream
/// consumers that already parse `mt rollback --list --json`.
pub fn writeEntriesJsonArray(w: *std.Io.Writer, entries: []const Entry) !void {
    try w.writeAll("[");
    for (entries, 0..) |e, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"sha256\":");
        try output.jsonStr(w, e.sha256);
        try w.writeAll(",\"version\":");
        try output.jsonStr(w, e.pkg_version);
        const secs: i64 = @intCast(@divTrunc(e.mtime_ns, std.time.ns_per_s));
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, ",\"mtime\":{d}", .{secs});
        try w.writeAll(s);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

const testing = std.testing;
const fs_test_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(fs_test_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

// --- parseArgs ----------------------------------------------------------

test "parseArgs accepts a bare package name" {
    const p = try parseArgs(&.{"wget"});
    try testing.expect(p.name != null);
    try testing.expectEqualStrings("wget", p.name.?);
    try testing.expect(!p.list_mode);
    try testing.expect(p.to_version == null);
}

test "parseArgs recognises --list anywhere in argv" {
    const p_pre = try parseArgs(&.{ "--list", "wget" });
    try testing.expect(p_pre.list_mode);
    try testing.expectEqualStrings("wget", p_pre.name.?);

    const p_post = try parseArgs(&.{ "wget", "--list" });
    try testing.expect(p_post.list_mode);
    try testing.expectEqualStrings("wget", p_post.name.?);
}

test "parseArgs reads --to <version> as a separated pair" {
    const p = try parseArgs(&.{ "--to", "1.23", "wget" });
    try testing.expect(p.to_version != null);
    try testing.expectEqualStrings("1.23", p.to_version.?);
    try testing.expectEqualStrings("wget", p.name.?);
}

test "parseArgs reads --to=<version> as a joined pair" {
    const p = try parseArgs(&.{ "--to=1.23", "wget" });
    try testing.expectEqualStrings("1.23", p.to_version.?);
    try testing.expectEqualStrings("wget", p.name.?);
}

test "parseArgs rejects --to without a value" {
    try testing.expectError(error.Aborted, parseArgs(&.{ "wget", "--to" }));
}

test "parseArgs rejects unknown flags" {
    try testing.expectError(error.Aborted, parseArgs(&.{ "wget", "--nope" }));
}

test "parseArgs picks the first non-flag arg as the package name" {
    // Belt-and-braces guard for the "--to <ver> <pkg>" shape: the version
    // value must not be reused as the package name on the next loop pass.
    const p = try parseArgs(&.{ "--to", "1.23", "wget", "extra" });
    try testing.expectEqualStrings("1.23", p.to_version.?);
    try testing.expectEqualStrings("wget", p.name.?);
}

test "parseArgs picks up --dry-run regardless of position" {
    const p = try parseArgs(&.{ "--dry-run", "wget" });
    try testing.expect(p.dry_run);
}

// --- formatIso8601 -------------------------------------------------------

test "formatIso8601 renders the unix epoch as 1970-01-01T00:00:00Z" {
    var buf: [32]u8 = undefined;
    const s = try formatIso8601(&buf, 0);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", s);
}

test "formatIso8601 clamps negative mtimes to the epoch" {
    // A pathological store entry with a pre-epoch mtime must not corrupt
    // the listing — the worst case is a noisy "1970-..." row.
    var buf: [32]u8 = undefined;
    const s = try formatIso8601(&buf, -1);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", s);
}

test "formatIso8601 zero-pads single-digit fields" {
    var buf: [32]u8 = undefined;
    // 2009-02-13T23:31:30Z
    const s = try formatIso8601(&buf, 1_234_567_890 * @as(i128, std.time.ns_per_s));
    try testing.expectEqualStrings("2009-02-13T23:31:30Z", s);
}

// --- writeListJson ------------------------------------------------------

test "writeListJson emits the documented shape" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const ns_per_s: i128 = std.time.ns_per_s;
    const entries = [_]Entry{
        .{ .sha256 = "aaa", .pkg_version = "1.24", .mtime_ns = 1_700_000_000 * ns_per_s },
        .{ .sha256 = "bbb", .pkg_version = "1.23", .mtime_ns = 1_699_000_000 * ns_per_s },
    };

    try writeListJson(&aw.writer, "wget", &entries);
    try testing.expectEqualStrings(
        "{\"name\":\"wget\",\"entries\":[" ++
            "{\"sha256\":\"aaa\",\"version\":\"1.24\",\"mtime\":1700000000}," ++
            "{\"sha256\":\"bbb\",\"version\":\"1.23\",\"mtime\":1699000000}" ++
            "]}\n",
        aw.written(),
    );
}

test "writeListJson with no entries emits an empty array" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try writeListJson(&aw.writer, "wget", &.{});
    try testing.expectEqualStrings("{\"name\":\"wget\",\"entries\":[]}\n", aw.written());
}

test "writeEntriesJsonArray emits a bare array compatible with rollback-list entries[]" {
    // The array is the splice point: `mt info` reuses it inside its own
    // object so downstream consumers can parse one shape across both
    // commands. Pinning the bytes here prevents drift between the
    // splice site and `writeListJson`'s consumers.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const ns_per_s: i128 = std.time.ns_per_s;
    const entries = [_]Entry{
        .{ .sha256 = "aaa", .pkg_version = "1.24", .mtime_ns = 1_700_000_000 * ns_per_s },
    };
    try writeEntriesJsonArray(&aw.writer, &entries);
    try testing.expectEqualStrings(
        "[{\"sha256\":\"aaa\",\"version\":\"1.24\",\"mtime\":1700000000}]",
        aw.written(),
    );
}

test "writeEntriesJsonArray emits [] when empty" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeEntriesJsonArray(&aw.writer, &.{});
    try testing.expectEqualStrings("[]", aw.written());
}

/// Resolve a store keg's placeholder from the formula source its bottle ships
/// at `.brew/<name>.rb`. Best-effort: null leaves the token in place, which
/// doctor's placeholder check then reports.
fn storeKegPlaceholder(
    io: std.Io,
    allocator: std.mem.Allocator,
    buf: []u8,
    prefix: []const u8,
    sha256: []const u8,
    name: []const u8,
    pkg_version: []const u8,
) ?formula_mod.Placeholder {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const keg_path = std.fmt.bufPrint(
        &path_buf,
        "{s}/store/{s}/{s}/{s}",
        .{ prefix, sha256, name, pkg_version },
    ) catch return null;

    const src = formula_mod.readKegSource(io, allocator, keg_path, name) orelse return null;
    defer allocator.free(src);

    var dep_buf: [64][]const u8 = undefined;
    const deps = formula_mod.declaredDependencies(&dep_buf, src);
    return formula_mod.dependencyPlaceholder(buf, prefix, deps);
}

/// Seed a `<prefix>/store/<sha>/<name>/<pkg_version>/INSTALL_RECEIPT.json`
/// tree. `delay_ms_after` lets the caller force monotonically increasing
/// mtimes across calls without depending on filesystem timer resolution
/// (HFS+/APFS round to seconds).
fn seedStoreEntry(
    io: std.Io,
    prefix: []const u8,
    sha: []const u8,
    name: []const u8,
    pkg_version: []const u8,
    delay_ms_after: u64,
) !void {
    var buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "{s}/store/{s}/{s}/{s}", .{ prefix, sha, name, pkg_version });
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var f_buf: [600]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&f_buf, "{s}/INSTALL_RECEIPT.json", .{dir});
    const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "{}");

    if (delay_ms_after > 0) {
        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(delay_ms_after * std.time.ns_per_ms)), .awake) catch {};
    }
}

test "collectCaskEntries returns history rows sorted newest-first" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // Order matters: even if rows are inserted out of order, the listing
    // must respect installed_at descending so the newest rollback target
    // shows first.
    try db.exec(
        \\INSERT INTO cask_versions (token, version, url, sha256, installed_at)
        \\VALUES ('flux-markdown', '1.30.0', 'https://x.invalid/a.dmg', 'aa', '2026-01-01T00:00:00'),
        \\       ('flux-markdown', '1.32.0', 'https://x.invalid/b.dmg', 'bb', '2026-03-01T00:00:00'),
        \\       ('flux-markdown', '1.31.0', 'https://x.invalid/c.dmg', 'cc', '2026-02-01T00:00:00');
    );

    var entries = try collectCaskEntries(testing.allocator, &db, "flux-markdown", null);
    defer freeEntries(testing.allocator, &entries);

    try testing.expectEqual(@as(usize, 3), entries.items.len);
    try testing.expectEqualStrings("1.32.0", entries.items[0].pkg_version);
    try testing.expectEqualStrings("1.31.0", entries.items[1].pkg_version);
    try testing.expectEqualStrings("1.30.0", entries.items[2].pkg_version);
}

test "collectCaskEntries drops the row matching skip_version" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO cask_versions (token, version, url, installed_at)
        \\VALUES ('flux-markdown', '1.30.0', 'u', '2026-01-01T00:00:00'),
        \\       ('flux-markdown', '1.32.0', 'u', '2026-03-01T00:00:00');
    );

    var entries = try collectCaskEntries(testing.allocator, &db, "flux-markdown", "1.32.0");
    defer freeEntries(testing.allocator, &entries);

    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("1.30.0", entries.items[0].pkg_version);
}

test "collectCaskEntries returns an empty list when the token has no history" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var entries = try collectCaskEntries(testing.allocator, &db, "missing-cask", null);
    defer freeEntries(testing.allocator, &entries);
    try testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "currentCaskVersion reads the installed cask version when present" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO casks (token, name, version, url)
        \\VALUES ('flux-markdown', 'flux-markdown', '1.32.427', 'https://x.invalid/f.dmg');
    );

    const v = currentCaskVersion(testing.allocator, &db, "flux-markdown") orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("1.32.427", v);
}

test "currentCaskVersion returns null when the token is unknown" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try testing.expect(currentCaskVersion(testing.allocator, &db, "missing") == null);
}

test "collectEntries returns an empty list when the store has no matching package" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("rb_collect_none");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(io, prefix);

    // Seed only `jq` so a search for `wget` returns no rows.
    try seedStoreEntry(io, prefix, "sha_x", "jq", "1.7", 0);

    var entries = try collectEntries(io, testing.allocator, prefix, "wget", null);
    defer freeEntries(testing.allocator, &entries);
    try testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "collectEntries surfaces StoreUnreadable when {prefix}/store does not exist" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("rb_collect_missing");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(io, prefix);

    // Deliberately do NOT create `<prefix>/store`. The error must be the
    // typed StoreUnreadable so the dispatcher can map it to a specific
    // user-facing message — collapsing it to OutOfMemory would lie.
    try testing.expectError(
        CollectError.StoreUnreadable,
        collectEntries(io, testing.allocator, prefix, "wget", null),
    );
}

test "collectEntries does not leak when allocator runs out mid-collection" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("rb_collect_oom");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(io, prefix);

    try seedStoreEntry(io, prefix, "sha_a", "wget", "1.20", 0);
    try seedStoreEntry(io, prefix, "sha_b", "wget", "1.21", 0);

    // checkAllAllocationFailures injects an allocator-failure at every
    // possible allocation point; if any path leaks or double-frees the
    // testing allocator catches it.
    const wrap = struct {
        fn run(allocator: std.mem.Allocator, pfx: []const u8, igio: std.Io) !void {
            var entries = collectEntries(igio, allocator, pfx, "wget", null) catch |e| switch (e) {
                CollectError.OutOfMemory => return error.OutOfMemory,
                CollectError.StoreUnreadable => return,
            };
            defer freeEntries(allocator, &entries);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, wrap.run, .{ prefix, io });
}

test "collectEntries returns store entries sorted newest-first by mtime" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("rb_collect");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(io, prefix);

    // Seed three versions with monotonically increasing mtimes. APFS rounds
    // mtimes to second precision on some FS configs, so a >=1.1s gap is
    // the cheapest reliable way to order them.
    try seedStoreEntry(io, prefix, "sha_old", "wget", "1.20", 1100);
    try seedStoreEntry(io, prefix, "sha_mid", "wget", "1.21", 1100);
    try seedStoreEntry(io, prefix, "sha_new", "wget", "1.22", 0);

    var entries = try collectEntries(io, testing.allocator, prefix, "wget", null);
    defer freeEntries(testing.allocator, &entries);

    try testing.expectEqual(@as(usize, 3), entries.items.len);
    try testing.expectEqualStrings("1.22", entries.items[0].pkg_version);
    try testing.expectEqualStrings("1.21", entries.items[1].pkg_version);
    try testing.expectEqualStrings("1.20", entries.items[2].pkg_version);
}

test "collectEntries skips the entry that matches skip_pkg_version" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("rb_collect_skip");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(io, prefix);

    try seedStoreEntry(io, prefix, "sha_a", "wget", "1.20", 1100);
    try seedStoreEntry(io, prefix, "sha_b", "wget", "1.21", 1100);
    try seedStoreEntry(io, prefix, "sha_c", "wget", "1.22", 0);

    var entries = try collectEntries(io, testing.allocator, prefix, "wget", "1.22");
    defer freeEntries(testing.allocator, &entries);

    try testing.expectEqual(@as(usize, 2), entries.items.len);
    try testing.expect(!std.mem.eql(u8, entries.items[0].pkg_version, "1.22"));
    try testing.expect(!std.mem.eql(u8, entries.items[1].pkg_version, "1.22"));
}

test "collectEntries ignores store entries that don't contain the named package" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("rb_collect_other");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(io, prefix);

    // Two `wget` entries plus an unrelated `jq` entry that must be filtered out.
    try seedStoreEntry(io, prefix, "sha_a", "wget", "1.20", 1100);
    try seedStoreEntry(io, prefix, "sha_b", "jq", "1.7", 1100);
    try seedStoreEntry(io, prefix, "sha_c", "wget", "1.21", 0);

    var entries = try collectEntries(io, testing.allocator, prefix, "wget", null);
    defer freeEntries(testing.allocator, &entries);

    try testing.expectEqual(@as(usize, 2), entries.items.len);
}

test "selectTargetIndex returns 0 (newest) when no version is requested" {
    const entries = [_]Entry{
        .{ .sha256 = "aaa", .pkg_version = "1.24", .mtime_ns = 0 },
        .{ .sha256 = "bbb", .pkg_version = "1.23", .mtime_ns = 0 },
    };
    try testing.expectEqual(@as(usize, 0), try selectTargetIndex(&entries, null));
}

test "selectTargetIndex with a requested version returns the matching index" {
    const entries = [_]Entry{
        .{ .sha256 = "aaa", .pkg_version = "1.24", .mtime_ns = 0 },
        .{ .sha256 = "bbb", .pkg_version = "1.23", .mtime_ns = 0 },
        .{ .sha256 = "ccc", .pkg_version = "1.22", .mtime_ns = 0 },
    };
    try testing.expectEqual(@as(usize, 1), try selectTargetIndex(&entries, "1.23"));
    try testing.expectEqual(@as(usize, 2), try selectTargetIndex(&entries, "1.22"));
}

test "selectTargetIndex returns NotFound when no entry matches the requested version" {
    const entries = [_]Entry{
        .{ .sha256 = "aaa", .pkg_version = "1.24", .mtime_ns = 0 },
    };
    try testing.expectError(SelectError.NotFound, selectTargetIndex(&entries, "9.9.9"));
}

test "selectTargetIndex returns NotFound on an empty list with no version" {
    try testing.expectError(SelectError.NotFound, selectTargetIndex(&.{}, null));
}

test "writeListHuman prints a header and one row per entry with ISO timestamps" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const ns_per_s: i128 = std.time.ns_per_s;
    const entries = [_]Entry{
        // 1_700_000_000 = 2023-11-14T22:13:20Z; 1_699_000_000 = 2023-11-03T08:26:40Z.
        .{ .sha256 = "aaa111", .pkg_version = "1.24", .mtime_ns = 1_700_000_000 * ns_per_s },
        .{ .sha256 = "bbb222", .pkg_version = "1.23", .mtime_ns = 1_699_000_000 * ns_per_s },
    };

    try writeListHuman(&aw.writer, "wget", &entries, false);

    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "wget") != null);
    try testing.expect(std.mem.indexOf(u8, out, "aaa111") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.24") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2023-11-14T22:13:20Z") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bbb222") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.23") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2023-11-03T08:26:40Z") != null);
    // Each row carries the bullet prefix used by `mt list --versions`.
    try testing.expect(std.mem.indexOf(u8, out, "  ▸ ") != null);

    // The newest row (aaa111) appears before the older row (bbb222) — caller is
    // expected to pass entries already sorted newest-first.
    const aaa_idx = std.mem.indexOf(u8, out, "aaa111").?;
    const bbb_idx = std.mem.indexOf(u8, out, "bbb222").?;
    try testing.expect(aaa_idx < bbb_idx);
}

test "writeListHuman with no entries still prints a header so users know the listing ran" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try writeListHuman(&aw.writer, "wget", &.{}, false);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "wget") != null);
}

test "writeListHuman with colorize=true wraps the package name in bold ANSI codes" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try writeListHuman(&aw.writer, "wget", &.{}, true);
    // Bold opens the package name; reset closes it. Both must appear.
    try testing.expect(std.mem.indexOf(u8, aw.written(), color.Style.bold.code()) != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), color.Style.reset.code()) != null);
}

test "writeListJson escapes embedded quotes in the package name" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try writeListJson(&aw.writer, "weird\"name", &.{});
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        std.mem.trimEnd(u8, aw.written(), "\n"),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("weird\"name", parsed.value.object.get("name").?.string);
}

test "replaceKegRow splits pkg_version into version + revision" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // Current keg at revision=2; rollback target is revision=0 of same upstream version.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, pinned)
        \\VALUES ('libgit2', 'libgit2', '1.9.2', 2, 'sha-cur', '/c/libgit2/1.9.2_2', 1);
    );
    const old_id = blk: {
        var s = try db.prepare("SELECT id FROM kegs WHERE name='libgit2';");
        defer s.finalize();
        _ = try s.step();
        break :blk s.columnInt(0);
    };

    const new_id = try replaceKegRow(&db, old_id, "libgit2", "1.9.2", "sha-old", "/c/libgit2/1.9.2", .{ .pinned = true, .bin_isolated = false });

    var stmt = try db.prepare("SELECT version, revision, pinned FROM kegs WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_id);
    _ = try stmt.step();
    const ver = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("1.9.2", std.mem.sliceTo(ver, 0));
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(1));
    try testing.expect(stmt.columnBool(2));
}

test "replaceKegRow recovers a non-zero revision from pkg_version" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('python@3.14', 'python@3.14', '3.14.4', 1, 'sha-cur', '/c/python@3.14/3.14.4_1');
    );
    const old_id = blk: {
        var s = try db.prepare("SELECT id FROM kegs WHERE name='python@3.14';");
        defer s.finalize();
        _ = try s.step();
        break :blk s.columnInt(0);
    };

    // Rolling back to an earlier revision-2 build.
    const new_id = try replaceKegRow(&db, old_id, "python@3.14", "3.14.3_2", "sha-old", "/c/python@3.14/3.14.3_2", .{ .pinned = false, .bin_isolated = false });

    var stmt = try db.prepare("SELECT version, revision FROM kegs WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_id);
    _ = try stmt.step();
    const ver = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("3.14.3", std.mem.sliceTo(ver, 0));
    try testing.expectEqual(@as(i64, 2), stmt.columnInt(1));

    // Old row was deleted in the same swap.
    var cnt = try db.prepare("SELECT COUNT(*) FROM kegs WHERE name='python@3.14';");
    defer cnt.finalize();
    _ = try cnt.step();
    try testing.expectEqual(@as(i64, 1), cnt.columnInt(0));
}

// A rolled-back keg the user had installed bin-isolated must stay
// bin-isolated: the swap replaces the version, not the user's intent.
test "replaceKegRow carries pinned and bin_isolated across the swap" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, pinned, bin_isolated)
        \\VALUES ('node', 'node', '22.1.0', 0, 'sha-cur', '/c/node/22.1.0', 1, 1);
    );
    const old_id = blk: {
        var s = try db.prepare("SELECT id FROM kegs WHERE name='node';");
        defer s.finalize();
        _ = try s.step();
        break :blk s.columnInt(0);
    };

    const new_id = try replaceKegRow(&db, old_id, "node", "22.0.0", "sha-old", "/c/node/22.0.0", .{
        .pinned = true,
        .bin_isolated = true,
    });

    var stmt = try db.prepare("SELECT pinned, bin_isolated FROM kegs WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_id);
    _ = try stmt.step();
    try testing.expect(stmt.columnBool(0));
    try testing.expect(stmt.columnBool(1));
}

test "replaceKegRow leaves a non-isolated keg non-isolated" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('jq', 'jq', '1.7.1', 0, 'sha-cur', '/c/jq/1.7.1');
    );
    const old_id = blk: {
        var s = try db.prepare("SELECT id FROM kegs WHERE name='jq';");
        defer s.finalize();
        _ = try s.step();
        break :blk s.columnInt(0);
    };

    const new_id = try replaceKegRow(&db, old_id, "jq", "1.7", "sha-old", "/c/jq/1.7", .{
        .pinned = false,
        .bin_isolated = false,
    });

    var stmt = try db.prepare("SELECT pinned, bin_isolated FROM kegs WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_id);
    _ = try stmt.step();
    try testing.expect(!stmt.columnBool(0));
    try testing.expect(!stmt.columnBool(1));
}

test "removeCurrentCellarDir wipes the revision-bumped on-disk dir" {
    const io = std.Options.debug_io;

    var s = try Scratch.init("rollback_cellar");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(io, prefix);

    // Cellar dirs are named after pkg_version, e.g. "1.9.2_2", not the
    // bare upstream "1.9.2" — passing the latter at rollback time orphans
    // the keg on disk.
    const name = "libgit2";
    const version = "1.9.2";
    const revision: i64 = 2;

    const keg_dir = s.p("/Cellar/libgit2/1.9.2_2");
    try std.Io.Dir.cwd().createDirPath(io, keg_dir);

    const sentinel = s.p("/Cellar/libgit2/1.9.2_2/INSTALL_RECEIPT.json");
    {
        const f = try std.Io.Dir.createFileAbsolute(io, sentinel, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{}");
    }

    try removeCurrentCellarDir(io, prefix, name, version, revision);

    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, keg_dir, .{}));
}

test "removeCurrentCellarDir wipes a plain version dir when revision is zero" {
    const io = std.Options.debug_io;

    var s = try Scratch.init("rollback_cellar_norev");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(io, prefix);

    const name = "tree";
    const version = "2.2.1";

    const keg_dir = s.p("/Cellar/tree/2.2.1");
    try std.Io.Dir.cwd().createDirPath(io, keg_dir);

    try removeCurrentCellarDir(io, prefix, name, version, 0);

    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, keg_dir, .{}));
}

test "dispatchCask acquires malt.lock before the reinstall mutation" {
    // dispatchCask drives a real CaskInstaller against a live prefix, so it
    // can't be exercised in isolation. The invariant that matters — the
    // uninstall+reinstall must serialize on the prefix lock, like every other
    // mutating command — is pinned at the source level: `LockFile.acquire`
    // must precede `reinstallFromHistory` inside the function body.
    const src = @embedFile("rollback.zig");
    const marker = "fn dispatchCask(";
    const start = std.mem.indexOf(u8, src, marker) orelse return error.DispatchCaskFnNotFound;

    var depth: usize = 0;
    var seen_open = false;
    var body_end: usize = 0;
    var i: usize = start + marker.len;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '{' => {
                depth += 1;
                seen_open = true;
            },
            '}' => {
                depth -= 1;
                if (seen_open and depth == 0) {
                    body_end = i;
                    break;
                }
            },
            else => {},
        }
    }
    try testing.expect(body_end > start);
    const body = src[start..body_end];

    const acquire_pos = std.mem.indexOf(u8, body, "LockFile.acquire") orelse
        return error.LockAcquireMissing;
    const mutate_pos = std.mem.indexOf(u8, body, "reinstallFromHistory") orelse
        return error.ReinstallCallMissing;
    try testing.expect(acquire_pos < mutate_pos);

    // Acquire failures must surface accurate per-error diagnostics via the
    // shared reporter, not a blanket "another process" message.
    try testing.expect(std.mem.indexOf(u8, body, "reportAcquireFailure") != null);
}
