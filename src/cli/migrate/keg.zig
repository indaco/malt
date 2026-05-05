//! Per-keg migrate work + supporting DB helpers. Mirrors the
//! `cli/install/{download,record}.zig` split: keep the wide-args
//! per-item function out of the orchestrator so the entry-point file
//! shrinks to flag parsing, scan, and dispatch.

const std = @import("std");
const AppCtx = @import("../../app_ctx.zig").AppCtx;
const sqlite = @import("../../db/sqlite.zig");
const formula_mod = @import("../../core/formula.zig");
const bottle_mod = @import("../../core/bottle.zig");
const store_mod = @import("../../core/store.zig");
const cellar_mod = @import("../../core/cellar.zig");
const linker_mod = @import("../../core/linker.zig");
const client_mod = @import("../../net/client.zig");
const ghcr_mod = @import("../../net/ghcr.zig");
const api_mod = @import("../../net/api.zig");
const atomic = @import("../../fs/atomic.zig");
const output = @import("../../ui/output.zig");
const post_install_mod = @import("../install/post_install.zig");
const post_install_queue_mod = @import("post_install_queue.zig");
const install_receipt_mod = @import("../../core/install_receipt.zig");

/// Result of migrating a single keg.
pub const KegResult = enum {
    migrated,
    skipped_installed,
    skipped_post_install,
    skipped_no_bottle,
    failed_api,
    failed_download,
    failed_install,
};

/// Named-field bundle for the shared state `migrateKeg` threads across
/// every keg in the loop. Opens a DI seam for tests to swap in fakes.
pub const MigrateDeps = struct {
    api: *api_mod.BrewApi,
    ghcr: *ghcr_mod.GhcrClient,
    http: *client_mod.HttpClient,
    store: *store_mod.Store,
    linker: *linker_mod.Linker,
    db: *sqlite.Database,
    prefix: []const u8,
    /// Source Homebrew install root — used as the read-only fallback
    /// when the brew API has no record of a keg (private/third-party
    /// taps); INSTALL_RECEIPT.json under each keg supplies the version
    /// + tap so we can copy + relocate the on-disk tree.
    homebrew_prefix: []const u8,
    use_system_ruby_scope: []const []const u8,
    /// Set by the parallel runner; null on the serial path so the
    /// default flow pays no lock cost.
    db_mu: ?*std.Io.Mutex = null,
    /// Defer post_install hooks here so they all run after every keg
    /// is materialised and linked under `opt/`; null falls back to
    /// inline drive (legacy / single-keg paths).
    post_install_queue: ?*post_install_queue_mod.Queue = null,
};

/// Migrate a single keg from Homebrew into malt.
pub fn migrateKeg(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    keg_name: []const u8,
    deps: MigrateDeps,
) KegResult {
    if (isInstalled(deps.db, keg_name)) {
        output.info("  {s}: already installed, skipping", .{keg_name});
        return .skipped_installed;
    }

    // Two `defer`s below collapse six per-branch cleanups.
    const formula_json = deps.api.fetchFormula(keg_name) catch |e| switch (e) {
        // `NotFound` is the only API outcome that triggers the
        // private-tap copy-from-Cellar fallback: the keg simply doesn't
        // exist in formulae.brew.sh because it lives in a third-party
        // tap. Network / response-shape / cache failures bypass the
        // fallback so a transient brew-api outage doesn't silently
        // shadow the canonical bottle path.
        error.NotFound => return migrateFromLocalCellar(ctx, allocator, keg_name, deps),
        else => {
            output.err("  {s}: Homebrew API fetch failed ({s})", .{ keg_name, @errorName(e) });
            return .failed_api;
        },
    };
    defer allocator.free(formula_json);

    var formula = formula_mod.parseFormula(allocator, formula_json) catch {
        output.err("  {s}: failed to parse formula JSON", .{keg_name});
        return .failed_api;
    };
    defer formula.deinit();

    const bottle = formula_mod.resolveBottle(allocator, &formula) catch {
        output.warn("  {s}: no bottle available for this platform", .{keg_name});
        return .skipped_no_bottle;
    };
    output.emitNdjsonEvent(allocator, .resolved, keg_name, null);

    output.info("  Migrating {s} {s}...", .{ formula.name, formula.version });

    if (!deps.store.exists(bottle.sha256)) {
        if (!downloadBottle(ctx, allocator, deps.ghcr, deps.http, deps.store, bottle.url, bottle.sha256, keg_name)) {
            return .failed_download;
        }
    } else {
        output.info("    {s} (cached in store)", .{keg_name});
    }
    if (output.isNdjson()) {
        output.emitNdjsonEvent(allocator, .downloaded, keg_name, "ok");
        output.emitNdjsonEvent(allocator, .extracted, keg_name, "ok");
        output.emitNdjsonEvent(allocator, .stored, keg_name, "ok");
    }

    deps.store.incrementRef(bottle.sha256) catch |e| {
        std.log.warn("refcount increment failed for {s}: {s}", .{ keg_name, @errorName(e) });
    };

    const keg = cellar_mod.materialize(
        ctx.io,
        allocator,
        deps.prefix,
        bottle.sha256,
        formula.name,
        formula.pkg_version,
    ) catch {
        output.err("    {s}: failed to materialize", .{keg_name});
        output.emitNdjsonEvent(allocator, .materialized, keg_name, "failed");
        return .failed_install;
    };
    output.emitNdjsonEvent(allocator, .materialized, keg_name, "ok");

    // Workers serialise on `db_mu` so transactions can't interleave;
    // serial callers leave `db_mu` null and pay no lock cost.
    if (deps.db_mu) |m| m.lockUncancelable(ctx.io);
    defer if (deps.db_mu) |m| m.unlock(ctx.io);

    if (!formula.keg_only) {
        const keg_id = recordKeg(deps.db, &formula, bottle.sha256, keg.path, "direct") catch {
            output.err("    {s}: failed to record in database", .{keg_name});
            cellar_mod.remove(ctx.io, deps.prefix, formula.name, formula.pkg_version) catch {};
            return .failed_install;
        };

        deps.linker.link(keg.path, formula.name, keg_id) catch {
            output.warn("    {s}: some links could not be created", .{keg_name});
            output.emitNdjsonEvent(allocator, .linked, keg_name, "failed");
            // Rollback: unlink partial links and delete keg row; user already warned above.
            deps.linker.unlink(keg_id) catch {};
            deleteKeg(deps.db, keg_id) catch {};
            cellar_mod.remove(ctx.io, deps.prefix, formula.name, formula.pkg_version) catch {};
            return .failed_install;
        };
        // `recorded` after both succeed — link rollback above undoes
        // the keg row, so an early emit would lie if link fails.
        output.emitNdjsonEvent(allocator, .linked, keg_name, "ok");
        output.emitNdjsonEvent(allocator, .recorded, keg_name, "ok");
        deps.linker.linkOpt(formula.name, formula.pkg_version) catch {};
        recordDeps(deps.db, keg_id, &formula);
    } else {
        const keg_id = recordKeg(deps.db, &formula, bottle.sha256, keg.path, "direct") catch {
            cellar_mod.remove(ctx.io, deps.prefix, formula.name, formula.pkg_version) catch {};
            return .failed_install;
        };
        output.emitNdjsonEvent(allocator, .recorded, keg_name, "ok");
        deps.linker.linkOpt(formula.name, formula.pkg_version) catch {};
        recordDeps(deps.db, keg_id, &formula);
    }

    if (formula.post_install_defined) {
        if (deps.post_install_queue) |q| {
            // Queue dupes the strings so the worker's per-iteration
            // arena is free to die before drain runs.
            q.add(ctx.io, formula.name, formula.pkg_version, formula_json) catch |e| {
                output.warn("    {s}: failed to queue post_install ({s}); running inline", .{ formula.name, @errorName(e) });
                post_install_mod.drive(
                    ctx,
                    allocator,
                    formula.name,
                    formula.pkg_version,
                    formula_json,
                    deps.prefix,
                    deps.use_system_ruby_scope,
                );
            };
        } else {
            post_install_mod.drive(
                ctx,
                allocator,
                formula.name,
                formula.pkg_version,
                formula_json,
                deps.prefix,
                deps.use_system_ruby_scope,
            );
        }
    }

    const keg_only_suffix: []const u8 = if (formula.keg_only) " (keg-only — dependency only)" else "";
    output.success("  {s} {s} migrated{s}", .{ formula.name, formula.version, keg_only_suffix });
    return .migrated;
}

/// Copy-from-Cellar fallback for kegs the brew API can't resolve
/// (private/third-party taps). Locates `<homebrew_prefix>/Cellar/<name>/`,
/// picks the version subdir whose `INSTALL_RECEIPT.json` mtime is
/// newest (matches brew's "current" version when multiples are present),
/// reads the receipt, and — if the recorded tap is non-core — copies
/// the keg tree into malt's Cellar via the same relocation pipeline
/// the bottle path uses. A `homebrew/core` keg that's missing from
/// the API is treated as a real API problem, not a fallback case:
/// returning `.failed_api` keeps the user's attention on the brew side
/// instead of papering over an upstream outage with a stale local copy.
fn migrateFromLocalCellar(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    keg_name: []const u8,
    deps: MigrateDeps,
) KegResult {
    const src_keg_path = findInstalledKegPath(ctx.io, allocator, deps.homebrew_prefix, keg_name) catch null orelse {
        output.err("  {s}: not found in Homebrew API and no local Cellar copy available", .{keg_name});
        return .failed_api;
    };
    defer allocator.free(src_keg_path);

    const receipt_text = readInstallReceipt(ctx.io, allocator, src_keg_path) catch {
        output.err("  {s}: local Cellar copy lacks a readable INSTALL_RECEIPT.json", .{keg_name});
        return .failed_api;
    };
    defer allocator.free(receipt_text);

    var receipt = install_receipt_mod.parseInstallReceipt(allocator, receipt_text) catch {
        output.err("  {s}: INSTALL_RECEIPT.json malformed", .{keg_name});
        return .failed_api;
    };
    defer receipt.deinit();

    if (install_receipt_mod.isCoreTap(receipt.tap)) {
        output.err("  {s}: not found in Homebrew API (homebrew/core keg — refusing local-Cellar fallback)", .{keg_name});
        return .failed_api;
    }
    if (receipt.version.len == 0) {
        output.err("  {s}: INSTALL_RECEIPT.json has no source.versions.stable", .{keg_name});
        return .failed_api;
    }

    output.info("  Migrating {s} {s} (from {s} tap)...", .{ keg_name, receipt.version, receipt.tap });

    const keg = cellar_mod.materializeFromLocalCellar(
        ctx.io,
        allocator,
        deps.prefix,
        src_keg_path,
        keg_name,
        receipt.version,
        receipt.tap,
        // Tap kegs don't carry a Homebrew bottle cellar_type tag here;
        // pass empty so the relocation pipeline treats it as a normal
        // bottle (full absolute-path rewrite + placeholder substitution).
        "",
    ) catch |e| {
        output.err("    {s}: failed to materialize from local Cellar ({s})", .{ keg_name, @errorName(e) });
        return .failed_install;
    };

    if (deps.db_mu) |m| m.lockUncancelable(ctx.io);
    defer if (deps.db_mu) |m| m.unlock(ctx.io);

    var full_name_buf: [256]u8 = undefined;
    const full_name = std.fmt.bufPrint(&full_name_buf, "{s}/{s}", .{ receipt.tap, keg_name }) catch keg_name;

    const keg_id = recordKegFields(deps.db, .{
        .name = keg_name,
        .full_name = full_name,
        .version = receipt.version,
        .revision = 0,
        .tap = receipt.tap,
        .store_sha256 = "",
        .cellar_path = keg.path,
        .install_reason = "direct",
    }) catch {
        output.err("    {s}: failed to record in database", .{keg_name});
        cellar_mod.remove(ctx.io, deps.prefix, keg_name, receipt.version) catch {};
        return .failed_install;
    };

    deps.linker.link(keg.path, keg_name, keg_id) catch {
        output.warn("    {s}: some links could not be created", .{keg_name});
        deps.linker.unlink(keg_id) catch {};
        deleteKeg(deps.db, keg_id) catch {};
        cellar_mod.remove(ctx.io, deps.prefix, keg_name, receipt.version) catch {};
        return .failed_install;
    };
    deps.linker.linkOpt(keg_name, receipt.version) catch {};
    recordDepsFromList(deps.db, keg_id, receipt.runtime_deps);

    output.success("  {s} {s} migrated (from {s} tap)", .{ keg_name, receipt.version, receipt.tap });
    return .migrated;
}

/// Locate the most recently-installed version subdir for `name` under
/// the source brew Cellar. Picks the one whose INSTALL_RECEIPT.json
/// mtime is highest so an upgrade-then-uninstall sequence still
/// migrates the version brew currently considers active. Returns the
/// caller-owned absolute path or null when no version dir carries a
/// receipt.
fn findInstalledKegPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    homebrew_prefix: []const u8,
    name: []const u8,
) !?[]const u8 {
    var cellar_buf: [512]u8 = undefined;
    const cellar_name_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}", .{ homebrew_prefix, name }) catch return null;

    var dir = std.Io.Dir.openDirAbsolute(io, cellar_name_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var best_path: ?[]const u8 = null;
    var best_mtime_ns: i96 = std.math.minInt(i96);
    errdefer if (best_path) |p| allocator.free(p);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var receipt_buf: [512]u8 = undefined;
        const receipt_rel = std.fmt.bufPrint(&receipt_buf, "{s}/INSTALL_RECEIPT.json", .{entry.name}) catch continue;
        const stat = dir.statFile(io, receipt_rel, .{}) catch continue;
        if (stat.kind != .file) continue;
        const mtime_ns = stat.mtime.toNanoseconds();
        if (mtime_ns > best_mtime_ns) {
            const new_full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cellar_name_path, entry.name });
            if (best_path) |old| allocator.free(old);
            best_path = new_full;
            best_mtime_ns = mtime_ns;
        }
    }
    return best_path;
}

/// Slurp `INSTALL_RECEIPT.json` from a keg directory. Caller owns.
/// Receipts are small (well under 1 MiB even for python with hundreds
/// of runtime deps); cap defensively to refuse a hostile/runaway file.
fn readInstallReceipt(
    io: std.Io,
    allocator: std.mem.Allocator,
    keg_path: []const u8,
) ![]u8 {
    var path_buf: [512]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&path_buf, "{s}/INSTALL_RECEIPT.json", .{keg_path});
    const file = try std.Io.Dir.openFileAbsolute(io, receipt_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const max_bytes: u64 = 1024 * 1024;
    if (stat.size > max_bytes) return error.ReceiptTooLarge;
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

/// Download a bottle from GHCR and commit to the store.
fn downloadBottle(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    ghcr: *ghcr_mod.GhcrClient,
    http: *client_mod.HttpClient,
    store: *store_mod.Store,
    bottle_url: []const u8,
    sha256: []const u8,
    name: []const u8,
) bool {
    const ghcr_prefix_str = "https://ghcr.io/v2/";
    var repo_buf: [256]u8 = undefined;
    var digest_buf: [128]u8 = undefined;

    if (!std.mem.startsWith(u8, bottle_url, ghcr_prefix_str)) {
        output.err("    {s}: unsupported bottle URL", .{name});
        return false;
    }

    const path = bottle_url[ghcr_prefix_str.len..];
    const blobs_pos = std.mem.indexOf(u8, path, "/blobs/") orelse {
        output.err("    {s}: malformed bottle URL", .{name});
        return false;
    };

    const repo = std.fmt.bufPrint(&repo_buf, "{s}", .{path[0..blobs_pos]}) catch return false;
    const digest = std.fmt.bufPrint(&digest_buf, "{s}", .{path[blobs_pos + "/blobs/".len ..]}) catch return false;

    const tmp_dir = atomic.createTempDir(ctx.io, allocator, name) catch return false;

    output.info("    Downloading {s}...", .{name});

    _ = bottle_mod.download(ctx.io, allocator, ghcr, http, repo, digest, sha256, tmp_dir, null) catch {
        output.err("    Download failed: {s}", .{name});
        atomic.cleanupTempDir(ctx.io, tmp_dir);
        allocator.free(tmp_dir);
        return false;
    };

    store.commitFrom(sha256, tmp_dir) catch {
        output.err("    Store commit failed: {s}", .{name});
        atomic.cleanupTempDir(ctx.io, tmp_dir);
        allocator.free(tmp_dir);
        return false;
    };
    allocator.free(tmp_dir);
    return true;
}

// ── DB helpers (same pattern as install.zig) ────────────────────────

/// Field bundle accepted by both the formula path (extracted from
/// `Formula`) and the local-Cellar fallback (extracted from
/// `INSTALL_RECEIPT.json`). Keeping the DB write surface flat means
/// the two callers exercise byte-identical SQL.
const KegFields = struct {
    name: []const u8,
    full_name: []const u8,
    version: []const u8,
    revision: i64,
    tap: []const u8,
    store_sha256: []const u8,
    cellar_path: []const u8,
    install_reason: []const u8,
};

fn recordKeg(
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    store_sha256: []const u8,
    cellar_path: []const u8,
    install_reason: []const u8,
) !i64 {
    return recordKegFields(db, .{
        .name = formula.name,
        .full_name = formula.full_name,
        .version = formula.version,
        .revision = formula.revision,
        .tap = formula.tap,
        .store_sha256 = store_sha256,
        .cellar_path = cellar_path,
        .install_reason = install_reason,
    });
}

fn recordKegFields(db: *sqlite.Database, f: KegFields) !i64 {
    db.beginTransaction() catch return error.RecordFailed;
    errdefer db.rollback();

    // The COALESCE on `pinned` carries any existing user pin across
    // INSERT OR REPLACE so re-migrating doesn't silently drop holds.
    var stmt = db.prepare(
        "INSERT OR REPLACE INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason, pinned)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, COALESCE((SELECT MAX(pinned) FROM kegs WHERE name = ?1), 0));",
    ) catch return error.RecordFailed;
    defer stmt.finalize();

    stmt.bindText(1, f.name) catch return error.RecordFailed;
    stmt.bindText(2, f.full_name) catch return error.RecordFailed;
    stmt.bindText(3, f.version) catch return error.RecordFailed;
    stmt.bindInt(4, f.revision) catch return error.RecordFailed;
    stmt.bindText(5, f.tap) catch return error.RecordFailed;
    stmt.bindText(6, f.store_sha256) catch return error.RecordFailed;
    stmt.bindText(7, f.cellar_path) catch return error.RecordFailed;
    stmt.bindText(8, f.install_reason) catch return error.RecordFailed;

    _ = stmt.step() catch return error.RecordFailed;

    const keg_id = getLastInsertId(db) catch return error.RecordFailed;
    db.commit() catch return error.RecordFailed;

    return keg_id;
}

fn deleteKeg(db: *sqlite.Database, keg_id: i64) sqlite.SqliteError!void {
    var stmt = try db.prepare("DELETE FROM kegs WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    _ = try stmt.step();
}

/// Each row is independent; skip on per-row failure so a partial dep
/// table is preferred to aborting a migration wholesale.
fn recordDeps(db: *sqlite.Database, keg_id: i64, formula: *const formula_mod.Formula) void {
    recordDepsFromList(db, keg_id, formula.dependencies);
}

/// Same SQL as `recordDeps` but takes a pre-extracted list — used by
/// the local-Cellar fallback whose dependency names come straight off
/// `INSTALL_RECEIPT.json` rather than a parsed Formula.
fn recordDepsFromList(db: *sqlite.Database, keg_id: i64, dep_names: []const []const u8) void {
    for (dep_names) |dep_name| {
        var stmt = db.prepare(
            "INSERT OR IGNORE INTO dependencies (keg_id, dep_name, dep_type) VALUES (?1, ?2, 'runtime');",
        ) catch continue;
        defer stmt.finalize();

        stmt.bindInt(1, keg_id) catch continue;
        stmt.bindText(2, dep_name) catch continue;
        _ = stmt.step() catch {};
    }
}

fn getLastInsertId(db: *sqlite.Database) !i64 {
    var stmt = db.prepare("SELECT last_insert_rowid();") catch return error.RecordFailed;
    defer stmt.finalize();
    const has_row = stmt.step() catch return error.RecordFailed;
    if (!has_row) return error.RecordFailed;
    return stmt.columnInt(0);
}

pub fn isInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}
