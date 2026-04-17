//! malt — migrate command
//! Import existing Homebrew installation.
//! Scans the Homebrew Cellar, resolves each keg via the Homebrew API,
//! downloads bottles through GHCR, and installs them via malt's atomic
//! install protocol. Never modifies the Homebrew installation.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const lock_mod = @import("../db/lock.zig");
const formula_mod = @import("../core/formula.zig");
const bottle_mod = @import("../core/bottle.zig");
const store_mod = @import("../core/store.zig");
const cellar_mod = @import("../core/cellar.zig");
const linker_mod = @import("../core/linker.zig");
const client_mod = @import("../net/client.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const api_mod = @import("../net/api.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const codesign = @import("../macho/codesign.zig");
const ruby_sub = @import("../core/ruby_subprocess.zig");
const dsl = @import("../core/dsl/root.zig");
const help = @import("help.zig");

fn inScope(scope: []const []const u8, name: []const u8) bool {
    for (scope) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Result of migrating a single keg.
const KegResult = enum {
    migrated,
    skipped_installed,
    skipped_post_install,
    skipped_no_bottle,
    failed_api,
    failed_download,
    failed_install,
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "migrate")) return;

    var dry_run = output.isDryRun();
    // Ruby is opt-in per keg only. A bare --use-system-ruby across a
    // whole `migrate` would widen the trust boundary to every
    // Homebrew-Cellar entry at once; refuse it and require names.
    var use_system_ruby_bare = false;
    var use_system_ruby_scope: std.ArrayList([]const u8) = .empty;
    defer use_system_ruby_scope.deinit(allocator);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) dry_run = true;
        if (std.mem.eql(u8, arg, "--use-system-ruby")) use_system_ruby_bare = true;
        if (std.mem.startsWith(u8, arg, "--use-system-ruby=")) {
            const list = arg["--use-system-ruby=".len..];
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |name| {
                if (name.len > 0) try use_system_ruby_scope.append(allocator, name);
            }
        }
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) output.setQuiet(true);
    }
    if (use_system_ruby_bare) {
        output.err(
            "bare --use-system-ruby is not allowed with `migrate`; scope it: --use-system-ruby=<name>[,<name>...]",
            .{},
        );
        return error.Aborted;
    }

    // ── Step 1: Detect Homebrew prefix ──────────────────────────────
    const brew_prefix = if (codesign.isArm64()) "/opt/homebrew" else "/usr/local";
    var cellar_buf: [256]u8 = undefined;
    const brew_cellar = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{brew_prefix}) catch return;

    fs_compat.accessAbsolute(brew_cellar, .{}) catch {
        output.err("No Homebrew installation found at {s}", .{brew_prefix});
        return error.Aborted;
    };

    output.info("Found Homebrew installation at {s}", .{brew_prefix});

    // ── Step 2: Scan Cellar for installed kegs ──────────────────────
    var dir = fs_compat.openDirAbsolute(brew_cellar, .{ .iterate = true }) catch {
        output.err("Cannot read Homebrew Cellar", .{});
        return error.Aborted;
    };
    defer dir.close();

    var keg_names: std.ArrayList([]const u8) = .empty;
    defer keg_names.deinit(allocator);

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const owned = allocator.dupe(u8, entry.name) catch continue;
        keg_names.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }

    if (keg_names.items.len == 0) {
        output.info("No kegs found in Homebrew Cellar", .{});
        return;
    }

    output.info("Found {d} package(s) in Homebrew Cellar", .{keg_names.items.len});

    // ── Dry-run mode: list and exit ─────────────────────────────────
    if (dry_run) {
        for (keg_names.items) |name| {
            output.info("  Would migrate: {s}", .{name});
        }
        output.info("Would migrate {d} packages from Homebrew", .{keg_names.items.len});
        output.warn("Run without --dry-run to perform migration", .{});
        return;
    }

    // ── Step 3: Initialize malt infrastructure ──────────────────────
    const prefix = atomic.maltPrefix();
    ensureDirs(prefix) catch return error.Aborted;

    // Open database
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database at {s}", .{db_path});
        return error.Aborted;
    };
    defer db.close();

    schema.initSchema(&db) catch {
        output.err("Failed to initialize database schema", .{});
        return error.Aborted;
    };

    // Acquire lock
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk = lock_mod.LockFile.acquire(lock_path, 30000) catch {
        output.err("Another mt process is running. Wait or run mt doctor.", .{});
        return error.Aborted;
    };
    defer lk.release();

    // Set up HTTP + API + GHCR + store + linker
    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    var cache_dir_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_dir_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    var ghcr = ghcr_mod.GhcrClient.init(allocator, &http);
    defer ghcr.deinit();

    var store = store_mod.Store.init(allocator, &db, prefix);
    var linker = linker_mod.Linker.init(allocator, &db, prefix);

    // ── Step 4: Migrate each keg ────────────────────────────────────
    var migrated: u32 = 0;
    var skipped: u32 = 0;
    var skipped_post_install: u32 = 0;
    var failed: u32 = 0;

    var skipped_names: std.ArrayList([]const u8) = .empty;
    defer skipped_names.deinit(allocator);
    var failed_names: std.ArrayList([]const u8) = .empty;
    defer failed_names.deinit(allocator);

    for (keg_names.items) |keg_name| {
        const result = migrateKeg(
            allocator,
            keg_name,
            &api,
            &ghcr,
            &http,
            &store,
            &linker,
            &db,
            prefix,
            use_system_ruby_scope.items,
        );

        switch (result) {
            .migrated => {
                migrated += 1;
            },
            .skipped_installed => {
                skipped += 1;
            },
            .skipped_post_install => {
                skipped_post_install += 1;
                skipped_names.append(allocator, keg_name) catch {};
            },
            .skipped_no_bottle => {
                skipped += 1;
                skipped_names.append(allocator, keg_name) catch {};
            },
            .failed_api, .failed_download, .failed_install => {
                failed += 1;
                failed_names.append(allocator, keg_name) catch {};
            },
        }
    }

    // ── Step 5: Report ──────────────────────────────────────────────
    output.info("", .{});
    output.info("Migration complete:", .{});
    output.info("  Migrated:              {d}", .{migrated});
    if (skipped > 0)
        output.info("  Skipped (installed):   {d}", .{skipped});
    if (skipped_post_install > 0) {
        output.warn("  Skipped (post_install): {d}", .{skipped_post_install});
        for (skipped_names.items) |name| {
            output.warn("    - {s} (needs post_install — use: brew install {s})", .{ name, name });
        }
    }
    if (failed > 0) {
        output.err("  Failed:                {d}", .{failed});
        for (failed_names.items) |name| {
            output.err("    - {s}", .{name});
        }
    }
}

/// Migrate a single keg from Homebrew into malt.
fn migrateKeg(
    allocator: std.mem.Allocator,
    keg_name: []const u8,
    api: *api_mod.BrewApi,
    ghcr: *ghcr_mod.GhcrClient,
    http: *client_mod.HttpClient,
    store: *store_mod.Store,
    linker: *linker_mod.Linker,
    db: *sqlite.Database,
    prefix: []const u8,
    use_system_ruby_scope: []const []const u8,
) KegResult {
    // 1. Check if already installed in malt
    if (isInstalled(db, keg_name)) {
        output.info("  {s}: already installed, skipping", .{keg_name});
        return .skipped_installed;
    }

    // 2. Resolve formula via Homebrew API
    const formula_json = api.fetchFormula(keg_name) catch {
        output.err("  {s}: not found in Homebrew API", .{keg_name});
        return .failed_api;
    };

    var formula = formula_mod.parseFormula(allocator, formula_json) catch {
        output.err("  {s}: failed to parse formula JSON", .{keg_name});
        allocator.free(formula_json);
        return .failed_api;
    };

    // 3. Resolve bottle for this platform
    const bottle = formula_mod.resolveBottle(allocator, &formula) catch {
        output.warn("  {s}: no bottle available for this platform", .{keg_name});
        formula.deinit();
        allocator.free(formula_json);
        return .skipped_no_bottle;
    };

    output.info("  Migrating {s} {s}...", .{ formula.name, formula.version });

    // 5. Download bottle via GHCR (skip if already in store)
    if (!store.exists(bottle.sha256)) {
        if (!downloadBottle(allocator, ghcr, http, store, bottle.url, bottle.sha256, keg_name)) {
            formula.deinit();
            allocator.free(formula_json);
            return .failed_download;
        }
    } else {
        output.info("    {s} (cached in store)", .{keg_name});
    }

    // Increment store refcount
    store.incrementRef(bottle.sha256) catch |e| {
        std.log.warn("refcount increment failed for {s}: {s}", .{ keg_name, @errorName(e) });
    };

    // 6. Materialize to cellar
    const keg = cellar_mod.materialize(
        allocator,
        prefix,
        bottle.sha256,
        formula.name,
        formula.version,
    ) catch {
        output.err("    {s}: failed to materialize", .{keg_name});
        formula.deinit();
        allocator.free(formula_json);
        return .failed_install;
    };

    // 7. Record in DB + link
    if (!formula.keg_only) {
        const keg_id = recordKeg(db, &formula, bottle.sha256, keg.path, "direct") catch {
            output.err("    {s}: failed to record in database", .{keg_name});
            cellar_mod.remove(prefix, formula.name, formula.version) catch {};
            formula.deinit();
            allocator.free(formula_json);
            return .failed_install;
        };

        linker.link(keg.path, formula.name, keg_id) catch {
            output.warn("    {s}: some links could not be created", .{keg_name});
            linker.unlink(keg_id) catch {};
            deleteKeg(db, keg_id);
            cellar_mod.remove(prefix, formula.name, formula.version) catch {};
            formula.deinit();
            allocator.free(formula_json);
            return .failed_install;
        };
        linker.linkOpt(formula.name, formula.version) catch {};
        recordDeps(db, keg_id, &formula);
    } else {
        const keg_id = recordKeg(db, &formula, bottle.sha256, keg.path, "direct") catch {
            cellar_mod.remove(prefix, formula.name, formula.version) catch {};
            formula.deinit();
            allocator.free(formula_json);
            return .failed_install;
        };
        linker.linkOpt(formula.name, formula.version) catch {};
        recordDeps(db, keg_id, &formula);
    }

    // Execute post_install: try DSL interpreter first, fall back to
    // system Ruby subprocess when --use-system-ruby is set.
    if (formula.post_install_defined) post_install: {
        const tap_path = ruby_sub.findHomebrewCoreTap();
        var rb_buf: [1024]u8 = undefined;
        const rb_path = if (tap_path) |tp| ruby_sub.resolveFormulaRbPath(&rb_buf, tp, formula.name) else null;

        if (rb_path) |src_path| {
            if (ruby_sub.extractPostInstallBody(allocator, src_path)) |post_install_src| {
                defer allocator.free(post_install_src);

                var flog = dsl.FallbackLog.init(allocator);
                defer flog.deinit();

                dsl.executePostInstall(allocator, &formula, post_install_src, prefix, &flog) catch {
                    if (flog.hasFatal()) {
                        output.warn("  post_install DSL failed for {s} (fatal)", .{formula.name});
                        flog.printFatal(formula.name);
                        break :post_install;
                    }
                    if (inScope(use_system_ruby_scope, formula.name)) {
                        ruby_sub.runPostInstall(allocator, formula.name, formula.version, prefix) catch |e| {
                            output.warn("  post_install subprocess failed for {s}: {s}", .{ formula.name, @errorName(e) });
                        };
                    } else {
                        output.warn("  {s}: post_install partially skipped (use --use-system-ruby={s} to attempt via Ruby)", .{ formula.name, formula.name });
                    }
                    break :post_install;
                };
                output.info("  post_install completed for {s}", .{formula.name});
                break :post_install;
            }
        }

        // No local .rb source — try fetching from GitHub
        if (ruby_sub.fetchPostInstallFromGitHub(allocator, formula.name)) |post_install_src| {
            defer allocator.free(post_install_src);

            var flog2 = dsl.FallbackLog.init(allocator);
            defer flog2.deinit();

            dsl.executePostInstall(allocator, &formula, post_install_src, prefix, &flog2) catch {
                if (flog2.hasFatal()) {
                    output.warn("  post_install DSL failed for {s} (fatal)", .{formula.name});
                    flog2.printFatal(formula.name);
                    break :post_install;
                }
                if (inScope(use_system_ruby_scope, formula.name)) {
                    ruby_sub.runPostInstall(allocator, formula.name, formula.version, prefix) catch |e| {
                        output.warn("  post_install subprocess failed for {s}: {s}", .{ formula.name, @errorName(e) });
                    };
                } else {
                    output.warn("  {s}: post_install partially skipped (use --use-system-ruby={s} to attempt via Ruby)", .{ formula.name, formula.name });
                }
                break :post_install;
            };
            output.info("  post_install completed for {s}", .{formula.name});
            break :post_install;
        }

        // No source available — fall back to subprocess or skip
        if (inScope(use_system_ruby_scope, formula.name)) {
            output.warn("  Running post_install for {s} via system Ruby...", .{formula.name});
            ruby_sub.runPostInstall(allocator, formula.name, formula.version, prefix) catch |e| {
                output.warn("  post_install failed for {s}: {s}", .{ formula.name, @errorName(e) });
            };
        } else {
            output.warn("  {s}: post_install skipped (use --use-system-ruby={s} or brew install {s})", .{ formula.name, formula.name, formula.name });
        }
    }

    const keg_only_suffix: []const u8 = if (formula.keg_only) " (keg-only — dependency only)" else "";
    output.success("  {s} {s} migrated{s}", .{ formula.name, formula.version, keg_only_suffix });
    return .migrated;
}

/// Download a bottle from GHCR and commit to the store.
fn downloadBottle(
    allocator: std.mem.Allocator,
    ghcr: *ghcr_mod.GhcrClient,
    http: *client_mod.HttpClient,
    store: *store_mod.Store,
    bottle_url: []const u8,
    sha256: []const u8,
    name: []const u8,
) bool {
    // Extract repo + digest from bottle URL
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

    // Create temp dir
    const tmp_dir = atomic.createTempDir(allocator, name) catch return false;

    output.info("    Downloading {s}...", .{name});

    // Download
    _ = bottle_mod.download(allocator, ghcr, http, repo, digest, sha256, tmp_dir, null) catch {
        output.err("    Download failed: {s}", .{name});
        atomic.cleanupTempDir(tmp_dir);
        allocator.free(tmp_dir);
        return false;
    };

    // Commit to store
    store.commitFrom(sha256, tmp_dir) catch {
        output.err("    Store commit failed: {s}", .{name});
        atomic.cleanupTempDir(tmp_dir);
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

    var stmt = db.prepare(
        "INSERT OR REPLACE INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);",
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

fn deleteKeg(db: *sqlite.Database, keg_id: i64) void {
    var stmt = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return;
    _ = stmt.step() catch {};
}

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

fn isInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}

/// Ensure all required directories under prefix exist.
fn ensureDirs(prefix: []const u8) !void {
    fs_compat.makeDirAbsolute(prefix) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            output.err("Cannot create prefix directory {s}", .{prefix});
            return error.Aborted;
        },
    };

    const subdirs = [_][]const u8{
        "store",
        "Cellar",
        "opt",
        "bin",
        "lib",
        "include",
        "share",
        "sbin",
        "etc",
        "tmp",
        "cache",
        "db",
    };

    for (subdirs) |subdir| {
        var buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ prefix, subdir }) catch continue;
        fs_compat.makeDirAbsolute(dir_path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => continue,
        };
    }
}
