//! malt — install command
//! Install formulas, casks, or tap formulas.
//! Implements the 9-step atomic install protocol.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const lock_mod = @import("../db/lock.zig");
const formula_mod = @import("../core/formula.zig");
const cask_mod = @import("../core/cask.zig");
const bottle_mod = @import("../core/bottle.zig");
const store_mod = @import("../core/store.zig");
const cellar_mod = @import("../core/cellar.zig");
const deps_mod = @import("../core/deps.zig");
const linker_mod = @import("../core/linker.zig");
const client_mod = @import("../net/client.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const api_mod = @import("../net/api.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");

pub const InstallError = error{
    NoPackages,
    DatabaseError,
    LockError,
    FormulaNotFound,
    CaskNotFound,
    NoBottle,
    DownloadFailed,
    StoreFailed,
    CellarFailed,
    LinkFailed,
    RecordFailed,
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse flags
    var packages: std.ArrayList([]const u8) = .empty;
    defer packages.deinit(allocator);
    var force_cask = false;
    var force_formula = false;
    var dry_run = false;
    var force = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cask")) {
            force_cask = true;
        } else if (std.mem.eql(u8, arg, "--formula")) {
            force_formula = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            output.setQuiet(true);
        } else if (std.mem.eql(u8, arg, "--json")) {
            output.setMode(.json);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            packages.append(allocator, arg) catch {};
        }
    }

    if (packages.items.len == 0) {
        output.err("No package names specified", .{});
        return InstallError.NoPackages;
    }

    // Initialize infrastructure
    const prefix = atomic.maltPrefix();

    // Ensure required directories exist (Step 0)
    ensureDirs(prefix);

    // Open database
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch
        return InstallError.DatabaseError;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database at {s}", .{db_path});
        return InstallError.DatabaseError;
    };
    defer db.close();

    // Initialize schema
    schema.initSchema(&db) catch {
        output.err("Failed to initialize database schema", .{});
        return InstallError.DatabaseError;
    };

    // Acquire lock (Step 1)
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch
        return InstallError.LockError;
    var lk = lock_mod.LockFile.acquire(lock_path, 30000) catch {
        output.err("Another mt process is running. Wait or run mt doctor.", .{});
        return InstallError.LockError;
    };
    defer lk.release();

    // Set up HTTP client
    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    // Set up API client
    var cache_dir_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_dir_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    // Set up GHCR client
    var ghcr = ghcr_mod.GhcrClient.init(allocator, &http);
    defer ghcr.deinit();

    // Set up store + linker
    var store = store_mod.Store.init(allocator, &db, prefix);
    var linker = linker_mod.Linker.init(allocator, &db, prefix);

    // Process each package
    for (packages.items) |pkg_name| {
        installPackage(
            allocator,
            pkg_name,
            &db,
            &api,
            &ghcr,
            &store,
            &linker,
            prefix,
            force_cask,
            force_formula,
            dry_run,
            force,
        ) catch |e| {
            output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
        };
    }
}

/// Install a single package (formula or cask).
fn installPackage(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    ghcr: *ghcr_mod.GhcrClient,
    store: *store_mod.Store,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    force_cask: bool,
    force_formula: bool,
    dry_run: bool,
    force: bool,
) !void {
    // Step 2: Auto-detect formula vs cask
    if (!force_cask) {
        // Try formula first (unless --cask)
        const formula_json = api.fetchFormula(pkg_name) catch {
            if (force_formula) {
                output.err("Formula '{s}' not found", .{pkg_name});
                return InstallError.FormulaNotFound;
            }
            // Fall through to cask
            return installCask(allocator, pkg_name, db, api, dry_run);
        };
        defer allocator.free(formula_json);

        return installFormula(
            allocator,
            pkg_name,
            formula_json,
            db,
            api,
            ghcr,
            store,
            linker,
            prefix,
            dry_run,
            force,
            "direct",
        );
    }

    // --cask was specified
    return installCask(allocator, pkg_name, db, api, dry_run);
}

/// Install a formula: resolve deps, download bottles, commit to store,
/// materialize to cellar, link, and record in DB.
fn installFormula(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    formula_json: []const u8,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    ghcr: *ghcr_mod.GhcrClient,
    store: *store_mod.Store,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
    install_reason: []const u8,
) !void {
    // Step 3: Parse formula
    var formula = formula_mod.parseFormula(allocator, formula_json) catch {
        output.err("Failed to parse formula JSON for '{s}'", .{pkg_name});
        return InstallError.FormulaNotFound;
    };
    defer formula.deinit();

    output.info("Installing {s} {s}", .{ formula.name, formula.version });

    // Check if already installed (skip unless --force)
    if (!force and isInstalled(db, formula.name)) {
        output.info("{s} is already installed", .{formula.name});
        return;
    }

    // Step 4: Resolve dependencies
    const deps = deps_mod.resolve(allocator, formula.name, api, db) catch &.{};
    defer {
        if (deps.len > 0) allocator.free(deps);
    }

    if (dry_run) {
        // --dry-run: show plan and return
        output.info("Dry run: would install {s} {s}", .{ formula.name, formula.version });
        if (deps.len > 0) {
            output.info("Dependencies to install:", .{});
            for (deps) |dep| {
                if (dep.already_installed) {
                    output.info("  {s} (already installed)", .{dep.name});
                } else {
                    output.info("  {s}", .{dep.name});
                }
            }
        }
        return;
    }

    // Step 5: Install dependencies first (topological order)
    for (deps) |dep| {
        if (dep.already_installed) continue;

        output.info("Installing dependency: {s}", .{dep.name});
        const dep_json = api.fetchFormula(dep.name) catch {
            output.warn("Could not fetch dependency {s}, skipping", .{dep.name});
            continue;
        };
        defer allocator.free(dep_json);

        installFormula(
            allocator,
            dep.name,
            dep_json,
            db,
            api,
            ghcr,
            store,
            linker,
            prefix,
            false,
            force,
            "dependency",
        ) catch |e| {
            output.warn("Failed to install dependency {s}: {s}", .{ dep.name, @errorName(e) });
        };
    }

    // Step 6: Select + download bottle
    const bottle = formula_mod.resolveBottle(allocator, &formula) catch {
        output.err("No bottle available for {s} on this platform", .{formula.name});
        return InstallError.NoBottle;
    };

    // Build GHCR repo path: homebrew/core/{name}
    var repo_buf: [256]u8 = undefined;
    const repo = std.fmt.bufPrint(&repo_buf, "homebrew/core/{s}", .{formula.name}) catch
        return InstallError.DownloadFailed;

    // Build digest from SHA256 for GHCR blob API
    var digest_buf: [128]u8 = undefined;
    const digest = std.fmt.bufPrint(&digest_buf, "sha256:{s}", .{bottle.sha256}) catch
        return InstallError.DownloadFailed;

    // Create temp dir for extraction
    const tmp_dir = atomic.createTempDir(allocator, formula.name) catch {
        output.err("Failed to create temp directory", .{});
        return InstallError.DownloadFailed;
    };
    defer atomic.cleanupTempDir(tmp_dir);
    defer allocator.free(tmp_dir);

    output.info("Downloading {s} bottle...", .{formula.name});

    const result = bottle_mod.download(
        allocator,
        ghcr,
        repo,
        digest,
        bottle.sha256,
        tmp_dir,
    ) catch {
        output.err("Failed to download bottle for {s}", .{formula.name});
        return InstallError.DownloadFailed;
    };

    // Step 7: Commit to store (atomic rename)
    output.info("Committing {s} to store...", .{formula.name});
    store.commit(result.sha256) catch {
        output.err("Failed to commit {s} to store", .{formula.name});
        return InstallError.StoreFailed;
    };

    // Increment ref count
    store.incrementRef(result.sha256) catch {};

    // Step 8: Materialize to cellar (clonefile + patch + codesign)
    output.info("Materializing {s} to cellar...", .{formula.name});
    const keg = cellar_mod.materialize(
        allocator,
        prefix,
        result.sha256,
        formula.name,
        formula.version,
    ) catch {
        output.err("Failed to materialize {s}", .{formula.name});
        return InstallError.CellarFailed;
    };

    // Step 9a: Link (create symlinks unless keg_only)
    if (!formula.keg_only) {
        output.info("Linking {s}...", .{formula.name});

        // Record in DB first to get keg_id for linking
        const keg_id = recordKeg(db, &formula, result.sha256, keg.path, install_reason) catch {
            output.err("Failed to record {s} in database", .{formula.name});
            return InstallError.RecordFailed;
        };

        // Check for conflicts
        _ = linker.checkConflicts(keg.path) catch {};

        // Link binaries, libs, etc.
        linker.link(keg.path, formula.name, keg_id) catch {
            output.warn("Some links for {s} could not be created", .{formula.name});
        };

        // Create opt link
        linker.linkOpt(formula.name, formula.version) catch {};

        // Record dependencies
        recordDeps(db, keg_id, &formula);
    } else {
        // Keg-only: still record in DB but skip linking
        output.info("{s} is keg-only; not linking", .{formula.name});

        const keg_id = recordKeg(db, &formula, result.sha256, keg.path, install_reason) catch {
            output.err("Failed to record {s} in database", .{formula.name});
            return InstallError.RecordFailed;
        };

        // Create opt link even for keg-only
        linker.linkOpt(formula.name, formula.version) catch {};

        // Record dependencies
        recordDeps(db, keg_id, &formula);
    }

    output.info("{s} {s} installed successfully", .{ formula.name, formula.version });
}

/// Install a cask (placeholder -- full implementation is a TODO).
fn installCask(
    allocator: std.mem.Allocator,
    token: []const u8,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    dry_run: bool,
) !void {
    const cask_json = api.fetchCask(token) catch {
        output.err("Cask '{s}' not found", .{token});
        return InstallError.CaskNotFound;
    };
    defer allocator.free(cask_json);

    var cask = cask_mod.parseCask(allocator, cask_json) catch {
        output.err("Failed to parse cask JSON for '{s}'", .{token});
        return InstallError.CaskNotFound;
    };
    defer cask.deinit();

    if (dry_run) {
        output.info("Dry run: would install cask {s} {s}", .{ cask.token, cask.version });
        return;
    }

    // TODO: Full cask install (download DMG/PKG/ZIP, extract, move to /Applications)
    output.warn("Cask installation is not yet implemented. Found: {s} {s}", .{ cask.token, cask.version });

    // Record in DB for tracking
    cask_mod.recordInstall(db, &cask, null) catch {};

    output.info("{s} {s} recorded (cask install pending implementation)", .{ cask.token, cask.version });
}

/// Record a keg in the database. Returns the keg_id.
fn recordKeg(
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    store_sha256: []const u8,
    cellar_path: []const u8,
    install_reason: []const u8,
) !i64 {
    db.beginTransaction() catch return InstallError.RecordFailed;
    errdefer db.rollback();

    var stmt = db.prepare(
        "INSERT OR REPLACE INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);",
    ) catch return InstallError.RecordFailed;
    defer stmt.finalize();

    stmt.bindText(1, formula.name) catch return InstallError.RecordFailed;
    stmt.bindText(2, formula.full_name) catch return InstallError.RecordFailed;
    stmt.bindText(3, formula.version) catch return InstallError.RecordFailed;
    stmt.bindInt(4, formula.revision) catch return InstallError.RecordFailed;
    stmt.bindText(5, formula.tap) catch return InstallError.RecordFailed;
    stmt.bindText(6, store_sha256) catch return InstallError.RecordFailed;
    stmt.bindText(7, cellar_path) catch return InstallError.RecordFailed;
    stmt.bindText(8, install_reason) catch return InstallError.RecordFailed;

    _ = stmt.step() catch return InstallError.RecordFailed;

    // Get last inserted row id
    const keg_id = getLastInsertId(db) catch return InstallError.RecordFailed;

    db.commit() catch return InstallError.RecordFailed;

    return keg_id;
}

/// Record dependencies for a keg.
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

/// Get the last inserted row id from SQLite.
fn getLastInsertId(db: *sqlite.Database) !i64 {
    var stmt = db.prepare("SELECT last_insert_rowid();") catch return InstallError.RecordFailed;
    defer stmt.finalize();
    const has_row = stmt.step() catch return InstallError.RecordFailed;
    if (!has_row) return InstallError.RecordFailed;
    return stmt.columnInt(0);
}

/// Check if a formula is already installed.
fn isInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}

/// Ensure all required directories under prefix exist.
fn ensureDirs(prefix: []const u8) void {
    const subdirs = [_][]const u8{
        "store",
        "Cellar",
        "Caskroom",
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
        std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => {
                // Try creating parent first
                std.fs.cwd().makePath(dir_path) catch {};
            },
        };
    }
}
