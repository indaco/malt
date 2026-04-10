//! malt — upgrade command
//! Upgrade installed packages and casks.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const lock_mod = @import("../db/lock.zig");
const client_mod = @import("../net/client.zig");
const api_mod = @import("../net/api.zig");
const cask_mod = @import("../core/cask.zig");
const formula_mod = @import("../core/formula.zig");
const bottle_mod = @import("../core/bottle.zig");
const store_mod = @import("../core/store.zig");
const cellar_mod = @import("../core/cellar.zig");
const linker_mod = @import("../core/linker.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "upgrade")) return;

    var cask_only = false;
    var formula_only = false;
    var dry_run = output.isDryRun();
    var pkg_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else if (std.mem.eql(u8, arg, "--cask")) {
            cask_only = true;
        } else if (std.mem.eql(u8, arg, "--formula")) {
            formula_only = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (pkg_name == null) pkg_name = arg;
        }
    }

    // Open DB + API
    const prefix = atomic.maltPrefix();

    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk = lock_mod.LockFile.acquire(lock_path, 5000) catch {
        output.err("Could not acquire lock. Another malt process may be running.", .{});
        return;
    };
    defer lk.release();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    var cache_dir_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_dir_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    if (pkg_name) |name| {
        // Upgrade a specific package — try formula first, then cask
        if (!cask_only) {
            if (isFormulaInstalled(&db, name)) {
                upgradeFormula(allocator, name, &db, &api, &http, prefix, dry_run);
                return;
            }
        }
        // Not a formula (or --cask): try cask
        upgradeCask(allocator, name, &db, &api, prefix, dry_run);
    } else {
        // Upgrade all
        if (!cask_only) {
            upgradeAllFormulas(allocator, &db, &api, &http, prefix, dry_run);
        }
        if (!formula_only) {
            upgradeAllCasks(allocator, &db, &api, prefix, dry_run);
        }
    }
}

// ---------------------------------------------------------------------------
// Formula upgrade
// ---------------------------------------------------------------------------

/// Upgrade a single installed formula with rollback safety.
///
/// Flow:
/// 1. Fetch latest version from API, compare with installed.
/// 2. Download + materialize new version to Cellar.
/// 3. Unlink old symlinks, create new ones atomically.
/// 4. Update DB (new keg record).
/// 5. On failure at ANY step after old symlinks are removed: restore old links.
/// 6. Only remove old Cellar entry after the new version is fully switched.
fn upgradeFormula(
    allocator: std.mem.Allocator,
    name: []const u8,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    http: *client_mod.HttpClient,
    prefix: [:0]const u8,
    dry_run: bool,
) void {
    // Step 1: Look up installed version from DB
    var find_stmt = db.prepare(
        "SELECT id, version, store_sha256, cellar_path FROM kegs WHERE name = ?1 LIMIT 1;",
    ) catch return;
    defer find_stmt.finalize();
    find_stmt.bindText(1, name) catch return;

    const found = find_stmt.step() catch false;
    if (!found) {
        output.err("{s} is not installed as a formula", .{name});
        return;
    }

    const old_keg_id = find_stmt.columnInt(0);
    const old_ver_ptr = find_stmt.columnText(1);
    const old_sha_ptr = find_stmt.columnText(2);
    const old_cellar_ptr = find_stmt.columnText(3);
    const old_version = if (old_ver_ptr) |v| std.mem.sliceTo(v, 0) else "unknown";
    const old_sha256 = if (old_sha_ptr) |s| std.mem.sliceTo(s, 0) else "";
    const old_cellar_path = if (old_cellar_ptr) |c| std.mem.sliceTo(c, 0) else "";

    // Step 2: Fetch latest formula from API
    const formula_json = api.fetchFormula(name) catch {
        output.err("Could not fetch formula info for {s}", .{name});
        return;
    };
    defer allocator.free(formula_json);

    var formula = formula_mod.parseFormula(allocator, formula_json) catch {
        output.err("Failed to parse formula JSON for {s}", .{name});
        return;
    };
    defer formula.deinit();

    // Compare versions
    if (std.mem.eql(u8, old_version, formula.version)) {
        output.info("{s} is already at latest version {s}", .{ name, formula.version });
        return;
    }

    output.info("Upgrading {s} {s} -> {s}...", .{ name, old_version, formula.version });

    if (dry_run) {
        output.info("Dry run: would upgrade {s} {s} -> {s}", .{ name, old_version, formula.version });
        return;
    }

    // Step 3: Resolve bottle for new version
    const bottle = formula_mod.resolveBottle(allocator, &formula) catch {
        output.err("No bottle available for {s} on this platform", .{name});
        return;
    };

    // Step 4: Download bottle
    var ghcr = ghcr_mod.GhcrClient.init(allocator, http);
    defer ghcr.deinit();

    var store = store_mod.Store.init(allocator, db, prefix);

    if (!store.exists(bottle.sha256)) {
        // Parse GHCR URL to extract repo + digest
        const ghcr_prefix_str = "https://ghcr.io/v2/";
        var repo_buf: [256]u8 = undefined;
        var digest_buf: [128]u8 = undefined;

        if (!std.mem.startsWith(u8, bottle.url, ghcr_prefix_str)) {
            output.err("Unsupported bottle URL for {s}", .{name});
            return;
        }
        const path = bottle.url[ghcr_prefix_str.len..];
        const blobs_pos = std.mem.indexOf(u8, path, "/blobs/") orelse {
            output.err("Malformed bottle URL for {s}", .{name});
            return;
        };
        const repo = std.fmt.bufPrint(&repo_buf, "{s}", .{path[0..blobs_pos]}) catch return;
        const digest = std.fmt.bufPrint(&digest_buf, "{s}", .{path[blobs_pos + "/blobs/".len ..]}) catch return;

        const tmp_dir = atomic.createTempDir(allocator, name) catch {
            output.err("Failed to create temp dir for {s}", .{name});
            return;
        };

        output.info("  Downloading {s}...", .{name});
        _ = bottle_mod.download(allocator, &ghcr, repo, digest, bottle.sha256, tmp_dir, null) catch {
            output.err("  Download failed: {s}", .{name});
            atomic.cleanupTempDir(tmp_dir);
            allocator.free(tmp_dir);
            return;
        };

        store.commitFrom(bottle.sha256, tmp_dir) catch {
            output.err("Failed to commit bottle to store for {s}", .{name});
            atomic.cleanupTempDir(tmp_dir);
            allocator.free(tmp_dir);
            return;
        };
        allocator.free(tmp_dir);

        store.incrementRef(bottle.sha256) catch {};
    }

    // Step 5: Materialize new version to Cellar
    output.dim("Materializing {s} to cellar...", .{name});
    const new_keg = cellar_mod.materialize(
        allocator,
        prefix,
        bottle.sha256,
        formula.name,
        formula.version,
    ) catch {
        output.err("Failed to materialize {s}", .{name});
        return;
    };

    // Step 6: Unlink old symlinks
    var linker = linker_mod.Linker.init(allocator, db, prefix);
    linker.unlink(old_keg_id) catch {
        output.warn("Could not remove old symlinks for {s}", .{name});
    };

    // Step 7: Create new symlinks — rollback on failure
    const new_keg_id = recordKeg(db, &formula, bottle.sha256, new_keg.path) catch {
        output.err("Failed to record new version of {s} in database", .{name});
        // Rollback: re-link old version
        restoreOldLinks(db, &linker, old_cellar_path, name, old_keg_id);
        cellar_mod.remove(prefix, formula.name, formula.version) catch {};
        return;
    };

    linker.link(new_keg.path, formula.name, new_keg_id) catch {
        output.err("Failed to link new version of {s}", .{name});
        // Rollback: remove partial new links, restore old
        linker.unlink(new_keg_id) catch {};
        deleteKeg(db, new_keg_id);
        restoreOldLinks(db, &linker, old_cellar_path, name, old_keg_id);
        cellar_mod.remove(prefix, formula.name, formula.version) catch {};
        return;
    };

    linker.linkOpt(formula.name, formula.version) catch {};

    // Step 8: Remove old DB record + Cellar entry (success path only)
    deleteKeg(db, old_keg_id);
    cellar_mod.remove(prefix, name, old_version) catch {
        output.warn("Could not remove old cellar entry for {s} {s}", .{ name, old_version });
    };
    // Also remove parent if empty
    {
        var parent_buf: [512]u8 = undefined;
        const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch "";
        if (parent_path.len > 0) {
            std.fs.cwd().deleteDir(parent_path) catch {};
        }
    }

    // Decrement store refcount for old bottle
    if (old_sha256.len > 0) {
        store.decrementRef(old_sha256) catch {};
    }

    output.success("{s} upgraded to {s}", .{ name, formula.version });
}

/// Re-link old version during rollback.
fn restoreOldLinks(
    _: *sqlite.Database,
    linker: *linker_mod.Linker,
    old_cellar_path: []const u8,
    name: []const u8,
    old_keg_id: i64,
) void {
    if (old_cellar_path.len == 0) return;
    linker.link(old_cellar_path, name, old_keg_id) catch {
        output.err("CRITICAL: Failed to restore old symlinks for {s}. Manual intervention may be required.", .{name});
    };
}

/// Record a keg in the database for upgrade. Returns the keg_id.
fn recordKeg(
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    store_sha256: []const u8,
    cellar_path: []const u8,
) !i64 {
    db.beginTransaction() catch return error.RecordFailed;
    errdefer db.rollback();

    var stmt = db.prepare(
        "INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'direct');",
    ) catch return error.RecordFailed;
    defer stmt.finalize();

    stmt.bindText(1, formula.name) catch return error.RecordFailed;
    stmt.bindText(2, formula.full_name) catch return error.RecordFailed;
    stmt.bindText(3, formula.version) catch return error.RecordFailed;
    stmt.bindInt(4, formula.revision) catch return error.RecordFailed;
    stmt.bindText(5, formula.tap) catch return error.RecordFailed;
    stmt.bindText(6, store_sha256) catch return error.RecordFailed;
    stmt.bindText(7, cellar_path) catch return error.RecordFailed;

    _ = stmt.step() catch return error.RecordFailed;

    const keg_id = getLastInsertId(db) catch return error.RecordFailed;

    db.commit() catch return error.RecordFailed;

    return keg_id;
}

/// Delete a keg record from the database (rollback helper).
fn deleteKeg(db: *sqlite.Database, keg_id: i64) void {
    // Also clean up dependencies
    {
        var dep_stmt = db.prepare("DELETE FROM dependencies WHERE keg_id = ?1;") catch return;
        defer dep_stmt.finalize();
        dep_stmt.bindInt(1, keg_id) catch return;
        _ = dep_stmt.step() catch {};
    }
    // Also clean up links
    {
        var link_stmt = db.prepare("DELETE FROM links WHERE keg_id = ?1;") catch return;
        defer link_stmt.finalize();
        link_stmt.bindInt(1, keg_id) catch return;
        _ = link_stmt.step() catch {};
    }
    var stmt = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return;
    _ = stmt.step() catch {};
}

/// Get the last inserted row id from SQLite.
fn getLastInsertId(db: *sqlite.Database) !i64 {
    var stmt = db.prepare("SELECT last_insert_rowid();") catch return error.RecordFailed;
    defer stmt.finalize();
    const has_row = stmt.step() catch return error.RecordFailed;
    if (!has_row) return error.RecordFailed;
    return stmt.columnInt(0);
}

/// Check if a formula is installed.
fn isFormulaInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}

/// Upgrade all outdated formulas.
fn upgradeAllFormulas(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    http: *client_mod.HttpClient,
    prefix: [:0]const u8,
    dry_run: bool,
) void {
    var stmt = db.prepare("SELECT name, version FROM kegs ORDER BY name;") catch return;
    defer stmt.finalize();

    // Collect names first to avoid holding the statement open during upgrade
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    while (stmt.step() catch false) {
        const name_ptr = stmt.columnText(0) orelse continue;
        const name_slice = std.mem.sliceTo(name_ptr, 0);
        const owned = allocator.dupe(u8, name_slice) catch continue;
        names.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }

    if (names.items.len == 0) {
        output.info("No formulas installed.", .{});
        return;
    }

    for (names.items) |name| {
        upgradeFormula(allocator, name, db, api, http, prefix, dry_run);
    }
}

// ---------------------------------------------------------------------------
// Cask upgrade
// ---------------------------------------------------------------------------

fn upgradeCask(allocator: std.mem.Allocator, token: []const u8, db: *sqlite.Database, api: *api_mod.BrewApi, prefix: [:0]const u8, dry_run: bool) void {
    const installed = cask_mod.lookupInstalled(db, token) orelse {
        output.err("{s} is not installed as a cask", .{token});
        return;
    };

    // Fetch latest version
    const cask_json = api.fetchCask(token) catch {
        output.err("Could not fetch cask info for {s}", .{token});
        return;
    };
    defer allocator.free(cask_json);

    var parsed_cask = cask_mod.parseCask(allocator, cask_json) catch {
        output.err("Failed to parse cask JSON for {s}", .{token});
        return;
    };
    defer parsed_cask.deinit();

    const installed_version = installed.version();
    if (std.mem.eql(u8, installed_version, parsed_cask.version)) {
        output.info("{s} is already at latest version {s}", .{ token, parsed_cask.version });
        return;
    }

    if (dry_run) {
        output.info("Dry run: would upgrade cask {s} {s} -> {s}", .{ token, installed_version, parsed_cask.version });
        return;
    }

    output.info("Upgrading {s} {s} -> {s}...", .{ token, installed_version, parsed_cask.version });

    // Uninstall old version
    var installer = cask_mod.CaskInstaller.init(allocator, db, prefix);
    installer.uninstall(token) catch {
        output.err("Failed to remove old version of {s}", .{token});
        return;
    };

    // Install new version
    const app_path = installer.install(&parsed_cask) catch {
        output.err("Failed to install new version of {s}", .{token});
        return;
    };

    cask_mod.recordInstall(db, &parsed_cask, app_path) catch {
        output.warn("Failed to record cask {s} in database", .{token});
    };
    allocator.free(app_path);

    output.success("{s} upgraded to {s}", .{ token, parsed_cask.version });
}

fn upgradeAllCasks(allocator: std.mem.Allocator, db: *sqlite.Database, api: *api_mod.BrewApi, prefix: [:0]const u8, dry_run: bool) void {
    var stmt = db.prepare("SELECT token, version FROM casks ORDER BY token;") catch return;
    defer stmt.finalize();

    var upgraded: u32 = 0;
    while (stmt.step() catch false) {
        const token_ptr = stmt.columnText(0) orelse continue;
        const token = std.mem.sliceTo(token_ptr, 0);

        upgradeCask(allocator, token, db, api, prefix, dry_run);
        upgraded += 1;
    }

    if (upgraded == 0) {
        output.info("All casks are up to date.", .{});
    }
}
