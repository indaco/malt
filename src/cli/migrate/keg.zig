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
    use_system_ruby_scope: []const []const u8,
    /// Set by the parallel runner; null on the serial path so the
    /// default flow pays no lock cost.
    db_mu: ?*std.Io.Mutex = null,
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
    const formula_json = deps.api.fetchFormula(keg_name) catch {
        output.err("  {s}: not found in Homebrew API", .{keg_name});
        return .failed_api;
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

    const keg_only_suffix: []const u8 = if (formula.keg_only) " (keg-only — dependency only)" else "";
    output.success("  {s} {s} migrated{s}", .{ formula.name, formula.version, keg_only_suffix });
    return .migrated;
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

fn recordKeg(
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    store_sha256: []const u8,
    cellar_path: []const u8,
    install_reason: []const u8,
) !i64 {
    db.beginTransaction() catch return error.RecordFailed;
    errdefer db.rollback();

    // The COALESCE on `pinned` carries any existing user pin across
    // INSERT OR REPLACE so re-migrating doesn't silently drop holds.
    var stmt = db.prepare(
        "INSERT OR REPLACE INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason, pinned)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, COALESCE((SELECT MAX(pinned) FROM kegs WHERE name = ?1), 0));",
    ) catch return error.RecordFailed;
    defer stmt.finalize();

    stmt.bindText(1, formula.name) catch return error.RecordFailed;
    stmt.bindText(2, formula.full_name) catch return error.RecordFailed;
    stmt.bindText(3, formula.version) catch return error.RecordFailed;
    stmt.bindInt(4, formula.revision) catch return error.RecordFailed;
    stmt.bindText(5, formula.tap) catch return error.RecordFailed;
    stmt.bindText(6, store_sha256) catch return error.RecordFailed;
    stmt.bindText(7, cellar_path) catch return error.RecordFailed;
    stmt.bindText(8, install_reason) catch return error.RecordFailed;

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
    for (formula.dependencies) |dep_name| {
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
