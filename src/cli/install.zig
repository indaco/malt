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
const help = @import("help.zig");

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

/// A bottle download job for parallel processing.
const DownloadJob = struct {
    name: []const u8,
    version_str: []const u8,
    sha256: []const u8,
    bottle_url: []const u8,
    is_dep: bool,
    keg_only: bool,
    formula_json: []const u8,
    /// Set after download completes
    store_sha256: []const u8,
    succeeded: bool,
};

/// Download a bottle and commit to store. Runs in a worker thread.
fn downloadWorker(_: std.mem.Allocator, ghcr: *ghcr_mod.GhcrClient, store: *store_mod.Store, job: *DownloadJob) void {
    // Each thread gets its own arena — the parent arena is not thread-safe.
    var thread_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer thread_arena.deinit();
    const allocator = thread_arena.allocator();

    // Skip if already in store
    if (store.exists(job.sha256)) {
        job.store_sha256 = job.sha256;
        job.succeeded = true;
        return;
    }

    // Extract repo + digest from bottle URL
    const ghcr_prefix_str = "https://ghcr.io/v2/";
    var repo_buf: [256]u8 = undefined;
    var digest_buf: [128]u8 = undefined;
    var repo: []const u8 = undefined;
    var digest: []const u8 = undefined;

    if (std.mem.startsWith(u8, job.bottle_url, ghcr_prefix_str)) {
        const path = job.bottle_url[ghcr_prefix_str.len..];
        if (std.mem.indexOf(u8, path, "/blobs/")) |blobs_pos| {
            repo = std.fmt.bufPrint(&repo_buf, "{s}", .{path[0..blobs_pos]}) catch return;
            digest = std.fmt.bufPrint(&digest_buf, "{s}", .{path[blobs_pos + "/blobs/".len ..]}) catch return;
        } else return;
    } else return;

    // Create temp dir
    const tmp_dir = atomic.createTempDir(allocator, job.name) catch return;

    output.info("  Downloading {s}...", .{job.name});

    // Download
    _ = bottle_mod.download(allocator, ghcr, repo, digest, job.sha256, tmp_dir) catch {
        output.err("  Download failed: {s}", .{job.name});
        atomic.cleanupTempDir(tmp_dir);
        allocator.free(tmp_dir);
        return;
    };

    // Commit to store
    store.commitFrom(job.sha256, tmp_dir) catch {
        atomic.cleanupTempDir(tmp_dir);
        allocator.free(tmp_dir);
        return;
    };
    allocator.free(tmp_dir);

    store.incrementRef(job.sha256) catch {};

    output.info("  Downloaded {s} ✓", .{job.name});
    job.store_sha256 = job.sha256;
    job.succeeded = true;
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "install")) return;

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

    // ── Collect all download jobs across all packages ────────────────
    var all_jobs: std.ArrayList(DownloadJob) = .empty;
    defer all_jobs.deinit(allocator);

    for (packages.items) |pkg_name| {
        // Handle tap formulas separately (they don't use GHCR)
        if (isTapFormula(pkg_name)) {
            installTapFormula(allocator, pkg_name, &db, &linker, prefix, dry_run, force) catch |e| {
                output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
            };
            continue;
        }

        // Try formula
        if (!force_cask) {
            const formula_json = api.fetchFormula(pkg_name) catch {
                if (force_formula) {
                    output.err("Formula '{s}' not found", .{pkg_name});
                    continue;
                }
                // Try cask
                installCask(allocator, pkg_name, &db, &api, dry_run) catch |e| {
                    output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
                };
                continue;
            };

            // Check if name also exists as a cask — warn about ambiguity
            if (!force_formula) {
                if (api.fetchCask(pkg_name)) |cask_json| {
                    allocator.free(cask_json);
                    output.info("{s} exists as both a formula and a cask. Installing formula. Use --cask to install the cask instead.", .{pkg_name});
                } else |_| {}
            }

            // Collect jobs for this formula + its deps
            collectFormulaJobs(allocator, pkg_name, formula_json, &api, &db, &store, force, &all_jobs) catch |e| {
                output.err("Failed to resolve {s}: {s}", .{ pkg_name, @errorName(e) });
                continue;
            };
        } else {
            installCask(allocator, pkg_name, &db, &api, dry_run) catch |e| {
                output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
            };
        }
    }

    if (all_jobs.items.len == 0) return;

    if (dry_run) {
        output.info("Dry run: would install {d} package(s):", .{all_jobs.items.len});
        for (all_jobs.items) |job| {
            const tag: []const u8 = if (job.is_dep) " (dependency)" else "";
            output.info("  {s} {s}{s}", .{ job.name, job.version_str, tag });
        }
        return;
    }

    // ── Parallel download phase ──────────────────────────────────────
    var to_download: u32 = 0;
    for (all_jobs.items) |*job| {
        if (store.exists(job.sha256)) {
            job.store_sha256 = job.sha256;
            job.succeeded = true;
        } else {
            to_download += 1;
        }
    }

    if (to_download > 0) {
        output.info("Downloading {d} bottle(s)...", .{to_download});

        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(allocator);

        for (all_jobs.items) |*job| {
            if (job.succeeded) {
                output.info("  {s} (cached)", .{job.name});
                continue;
            }
            const t = std.Thread.spawn(.{}, downloadWorker, .{
                allocator, &ghcr, &store, job,
            }) catch {
                downloadWorker(allocator, &ghcr, &store, job);
                continue;
            };
            threads.append(allocator, t) catch {
                t.join();
                continue;
            };
        }

        for (threads.items) |t| t.join();
    }

    // Check for Ctrl-C between download and materialize phases
    const main_mod = @import("../main.zig");
    if (main_mod.isInterrupted()) {
        output.warn("Interrupted. Cleaning up...", .{});
        return;
    }

    // ── Sequential materialize + link phase ──────────────────────────
    for (all_jobs.items) |*job| {
        if (main_mod.isInterrupted()) {
            output.warn("Interrupted. Stopping install.", .{});
            return;
        }

        if (!job.succeeded) {
            output.err("Download failed for {s}, skipping", .{job.name});
            continue;
        }

        materializeAndLink(allocator, job, &db, &linker, prefix);
    }
}

/// Collect download jobs for a formula and all its dependencies.
/// Appends to the shared jobs list for parallel download.
fn collectFormulaJobs(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    formula_json: []const u8,
    api: *api_mod.BrewApi,
    db: *sqlite.Database,
    store: *store_mod.Store,
    force: bool,
    jobs: *std.ArrayList(DownloadJob),
) !void {
    _ = store;
    var formula = formula_mod.parseFormula(allocator, formula_json) catch |e| {
        output.err("Failed to parse formula JSON for '{s}': {s}", .{ pkg_name, @errorName(e) });
        return InstallError.FormulaNotFound;
    };

    // Check if already installed
    if (!force and isInstalled(db, formula.name)) {
        output.info("{s} is already installed", .{formula.name});
        formula.deinit();
        return;
    }

    // Resolve dependencies
    const deps = deps_mod.resolve(allocator, formula.name, api, db) catch &.{};

    // Add deps as jobs
    for (deps) |dep| {
        if (dep.already_installed) continue;

        const dep_json = api.fetchFormula(dep.name) catch continue;
        var dep_formula = formula_mod.parseFormula(allocator, dep_json) catch {
            allocator.free(dep_json);
            continue;
        };
        const dep_bottle = formula_mod.resolveBottle(allocator, &dep_formula) catch {
            dep_formula.deinit();
            allocator.free(dep_json);
            continue;
        };

        // Check for duplicate (another top-level pkg may share a dep)
        var is_dup = false;
        for (jobs.items) |existing| {
            if (std.mem.eql(u8, existing.sha256, dep_bottle.sha256)) {
                is_dup = true;
                break;
            }
        }
        if (is_dup) {
            dep_formula.deinit();
            allocator.free(dep_json);
            continue;
        }

        jobs.append(allocator, .{
            .name = dep_formula.name,
            .version_str = dep_formula.version,
            .sha256 = dep_bottle.sha256,
            .bottle_url = dep_bottle.url,
            .is_dep = true,
            .keg_only = dep_formula.keg_only,
            .formula_json = dep_json,
            .store_sha256 = "",
            .succeeded = false,
        }) catch continue;
    }

    // Add main formula
    const bottle = formula_mod.resolveBottle(allocator, &formula) catch {
        output.err("No bottle available for {s} on this platform", .{formula.name});
        return InstallError.NoBottle;
    };

    jobs.append(allocator, .{
        .name = formula.name,
        .version_str = formula.version,
        .sha256 = bottle.sha256,
        .bottle_url = bottle.url,
        .is_dep = false,
        .keg_only = formula.keg_only,
        .formula_json = formula_json,
        .store_sha256 = "",
        .succeeded = false,
    }) catch return InstallError.DownloadFailed;

    // Warn if formula defines post_install — malt cannot run Ruby post-install scripts
    if (formula.post_install_defined) {
        output.warn("{s} defines a post_install script that malt cannot execute.", .{formula.name});
        output.warn("The package may not work correctly without it. Consider: brew install {s}", .{formula.name});
    }

    output.info("Resolved {s} {s} ({d} packages)", .{ formula.name, formula.version, jobs.items.len });
}

/// Materialize a downloaded bottle to the cellar, link, and record in DB.
fn materializeAndLink(
    allocator: std.mem.Allocator,
    job: *DownloadJob,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
) void {
    const reason: []const u8 = if (job.is_dep) "dependency" else "direct";

    output.info("Materializing {s} to cellar...", .{job.name});
    const keg = cellar_mod.materialize(
        allocator,
        prefix,
        job.store_sha256,
        job.name,
        job.version_str,
    ) catch {
        output.err("Failed to materialize {s}", .{job.name});
        return;
    };
    // Parse formula for DB recording
    var formula = formula_mod.parseFormula(allocator, job.formula_json) catch {
        output.err("Failed to parse formula for {s}", .{job.name});
        cellar_mod.remove(prefix, job.name, job.version_str) catch {};
        return;
    };
    defer formula.deinit();

    // Check for symlink conflicts before linking
    if (!job.keg_only) {
        const conflicts = linker.checkConflicts(keg.path) catch &.{};
        if (conflicts.len > 0) {
            output.err("{s}: {d} symlink conflict(s) detected:", .{ job.name, conflicts.len });
            for (conflicts) |conflict| {
                output.err("  {s} already linked by {s}", .{ conflict.link_path, conflict.existing_keg });
            }
            output.err("Use --force to overwrite, or uninstall the conflicting package first.", .{});
            cellar_mod.remove(prefix, job.name, job.version_str) catch {};
            return;
        }
    }

    // Link + record
    if (!job.keg_only) {
        const keg_id = recordKeg(db, &formula, job.store_sha256, keg.path, reason) catch {
            output.err("Failed to record {s} in database", .{job.name});
            cellar_mod.remove(prefix, job.name, job.version_str) catch {};
            return;
        };

        linker.link(keg.path, job.name, keg_id) catch {
            output.warn("Some links for {s} could not be created", .{job.name});
            // Rollback: unlink what was partially created + remove DB record + cellar
            linker.unlink(keg_id) catch {};
            deleteKeg(db, keg_id);
            cellar_mod.remove(prefix, job.name, job.version_str) catch {};
            return;
        };
        linker.linkOpt(job.name, job.version_str) catch {};
        recordDeps(db, keg_id, &formula);
    } else {
        output.info("{s} is keg-only; not linking", .{job.name});
        const keg_id = recordKeg(db, &formula, job.store_sha256, keg.path, reason) catch {
            cellar_mod.remove(prefix, job.name, job.version_str) catch {};
            return;
        };
        linker.linkOpt(job.name, job.version_str) catch {};
        recordDeps(db, keg_id, &formula);
    }
    output.success("{s} {s} installed", .{ job.name, job.version_str });
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

/// Delete a keg record from the database (rollback helper).
fn deleteKeg(db: *sqlite.Database, keg_id: i64) void {
    var stmt = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return;
    _ = stmt.step() catch {};
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
    // Create the prefix directory itself first (e.g. /opt/malt)
    std.fs.makeDirAbsolute(prefix) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            output.err("Cannot create prefix directory {s} — you may need: sudo mkdir -p {s} && sudo chown $USER {s}", .{ prefix, prefix, prefix });
            return;
        },
    };

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
            else => continue,
        };
    }
}

/// Build GHCR repo path from formula name, replacing @ with /
fn buildGhcrRepo(buf: []u8, name: []const u8) ![]const u8 {
    // Replace @ with / for versioned formulas (openssl@3 -> homebrew/core/openssl/3)
    var pos: usize = 0;
    const prefix_str = "homebrew/core/";
    if (pos + prefix_str.len > buf.len) return error.OutOfMemory;
    @memcpy(buf[pos .. pos + prefix_str.len], prefix_str);
    pos += prefix_str.len;

    for (name) |ch| {
        if (pos >= buf.len) return error.OutOfMemory;
        buf[pos] = if (ch == '@') '/' else ch;
        pos += 1;
    }
    return buf[0..pos];
}

/// Check if a package name is a tap formula (user/repo/formula format).
fn isTapFormula(name: []const u8) bool {
    var slash_count: u32 = 0;
    for (name) |ch| {
        if (ch == '/') slash_count += 1;
    }
    return slash_count == 2;
}

/// Parse a tap formula name into user, repo, formula components.
fn parseTapName(name: []const u8) ?struct { user: []const u8, repo: []const u8, formula: []const u8 } {
    const first_slash = std.mem.indexOfScalar(u8, name, '/') orelse return null;
    const rest = name[first_slash + 1 ..];
    const second_slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return .{
        .user = name[0..first_slash],
        .repo = rest[0..second_slash],
        .formula = rest[second_slash + 1 ..],
    };
}

/// Install a tap formula by fetching the Ruby formula from GitHub and
/// extracting URL + SHA256 for the current platform.
fn installTapFormula(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
) !void {
    const parts = parseTapName(pkg_name) orelse {
        output.err("Invalid tap formula format: {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    };

    output.info("Resolving tap {s}/{s}/{s}...", .{ parts.user, parts.repo, parts.formula });

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    // Try Formula/ first, then Casks/
    var url_buf: [512]u8 = undefined;
    const rb_url = std.fmt.bufPrint(&url_buf, "https://raw.githubusercontent.com/{s}/homebrew-{s}/HEAD/Formula/{s}.rb", .{
        parts.user,
        parts.repo,
        parts.formula,
    }) catch return InstallError.FormulaNotFound;

    var resp = http.get(rb_url) catch {
        output.err("Cannot fetch tap from GitHub", .{});
        return InstallError.FormulaNotFound;
    };

    if (resp.status != 200) {
        resp.deinit();
        // Try Casks/ directory
        const cask_url = std.fmt.bufPrint(&url_buf, "https://raw.githubusercontent.com/{s}/homebrew-{s}/HEAD/Casks/{s}.rb", .{
            parts.user,
            parts.repo,
            parts.formula,
        }) catch return InstallError.FormulaNotFound;

        resp = http.get(cask_url) catch {
            output.err("Cannot fetch tap from GitHub", .{});
            return InstallError.FormulaNotFound;
        };
    }
    defer resp.deinit();

    if (resp.status != 200) {
        output.err("Tap formula/cask not found: {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    }

    // Parse the Ruby formula to extract name, version, URL, SHA256 for current arch
    const rb = parseRubyFormula(resp.body) orelse {
        output.err("Cannot parse tap formula (Ruby format). Use: brew install {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    };

    // Interpolate #{version} in URL if present
    const version_needle = "#" ++ "{version}";
    var final_url_buf: [512]u8 = undefined;
    const final_url = blk: {
        if (std.mem.indexOf(u8, rb.url, version_needle)) |pos| {
            const before = rb.url[0..pos];
            const after = rb.url[pos + version_needle.len ..];
            break :blk std.fmt.bufPrint(&final_url_buf, "{s}{s}{s}", .{ before, rb.version, after }) catch rb.url;
        }
        break :blk rb.url;
    };

    output.info("Found {s} {s}", .{ parts.formula, rb.version });

    if (dry_run) {
        output.info("Dry run: would install {s} {s} from {s}", .{ parts.formula, rb.version, final_url });
        return;
    }

    // Check if already installed
    if (!force and isInstalled(db, parts.formula)) {
        output.info("{s} is already installed", .{parts.formula});
        return;
    }

    // Download the binary archive
    output.info("Downloading {s}...", .{parts.formula});
    var download_resp = http.get(final_url) catch {
        output.err("Failed to download {s}", .{parts.formula});
        return InstallError.DownloadFailed;
    };
    defer download_resp.deinit();

    if (download_resp.status != 200) {
        output.err("Download failed with status {d}", .{download_resp.status});
        return InstallError.DownloadFailed;
    }

    // Verify SHA256
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(download_resp.body, &hash, .{});
    var hex_buf: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    const computed: []const u8 = &hex_buf;

    if (!std.mem.eql(u8, computed, rb.sha256)) {
        output.err("SHA256 mismatch for {s}", .{parts.formula});
        return InstallError.DownloadFailed;
    }

    // Extract to Cellar directly (tap binaries are simple archives)
    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ prefix, parts.formula, rb.version }) catch
        return InstallError.CellarFailed;

    // Create cellar directory
    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, parts.formula }) catch
        return InstallError.CellarFailed;
    std.fs.makeDirAbsolute(parent) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };
    std.fs.makeDirAbsolute(cellar_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };

    // Create bin subdirectory and extract
    var bin_buf: [512]u8 = undefined;
    const bin_path = std.fmt.bufPrint(&bin_buf, "{s}/bin", .{cellar_path}) catch
        return InstallError.CellarFailed;
    std.fs.makeDirAbsolute(bin_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };

    // Write archive to temp file
    const is_xz = std.mem.endsWith(u8, final_url, ".tar.xz");
    const ext = if (is_xz) ".tar.xz" else ".tar.gz";
    var tmp_buf: [512]u8 = undefined;
    const tmp_archive = std.fmt.bufPrint(&tmp_buf, "{s}/tmp/tap_download{s}", .{ prefix, ext }) catch
        return InstallError.DownloadFailed;

    const tmp_file = std.fs.createFileAbsolute(tmp_archive, .{}) catch return InstallError.DownloadFailed;
    tmp_file.writeAll(download_resp.body) catch {
        tmp_file.close();
        return InstallError.DownloadFailed;
    };
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_archive) catch {};

    // Extract archive to cellar
    const archive_mod = @import("../fs/archive.zig");
    if (is_xz) {
        // Use system tar for .tar.xz (Zig xz decompressor uses legacy I/O API)
        archive_mod.extractTarXzFile(tmp_archive, cellar_path) catch {
            output.err("Failed to extract .tar.xz archive for {s}", .{parts.formula});
            return InstallError.CellarFailed;
        };
    } else {
        var out_dir = std.fs.openDirAbsolute(cellar_path, .{}) catch return InstallError.CellarFailed;
        defer out_dir.close();

        const archive_file = std.fs.openFileAbsolute(tmp_archive, .{}) catch return InstallError.CellarFailed;
        defer archive_file.close();

        var read_buf: [8192]u8 = undefined;
        var file_reader = archive_file.reader(&read_buf);
        archive_mod.extractTarGz(&file_reader.interface, out_dir) catch {
            output.err("Failed to extract archive for {s}", .{parts.formula});
            return InstallError.CellarFailed;
        };
    }

    // Find and move the binary to bin/
    // GoReleaser may extract directly or into a subdirectory
    {
        var cellar_dir = std.fs.openDirAbsolute(cellar_path, .{ .iterate = true }) catch return InstallError.CellarFailed;
        defer cellar_dir.close();

        // Walk all files (including subdirectories) looking for the formula binary
        var walker = cellar_dir.walk(allocator) catch return InstallError.CellarFailed;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;

            // Match binary by formula name (the basename, not the full path)
            const basename = std.fs.path.basename(entry.path);
            if (std.mem.eql(u8, basename, parts.formula)) {
                // Copy to bin/
                const dest_name = std.fmt.bufPrint(&tmp_buf, "bin/{s}", .{basename}) catch continue;
                cellar_dir.copyFile(entry.path, cellar_dir, dest_name, .{}) catch continue;
                // Make executable
                const bin_file = cellar_dir.openFile(dest_name, .{ .mode = .read_write }) catch continue;
                defer bin_file.close();
                bin_file.chmod(0o755) catch {};
                break;
            }
        }
    }

    // Link
    output.info("Linking {s}...", .{parts.formula});

    // Record in DB first to get keg_id
    db.beginTransaction() catch return InstallError.RecordFailed;
    errdefer db.rollback();

    var keg_id: i64 = 0;
    {
        var stmt = db.prepare(
            "INSERT OR REPLACE INTO kegs (name, full_name, version, tap, store_sha256, cellar_path, install_reason)" ++
                " VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'direct');",
        ) catch return InstallError.RecordFailed;
        defer stmt.finalize();
        stmt.bindText(1, parts.formula) catch return InstallError.RecordFailed;
        stmt.bindText(2, pkg_name) catch return InstallError.RecordFailed;
        stmt.bindText(3, rb.version) catch return InstallError.RecordFailed;

        var tap_buf: [128]u8 = undefined;
        const tap_name = std.fmt.bufPrint(&tap_buf, "{s}/{s}", .{ parts.user, parts.repo }) catch return InstallError.RecordFailed;
        stmt.bindText(4, tap_name) catch return InstallError.RecordFailed;
        stmt.bindText(5, rb.sha256) catch return InstallError.RecordFailed;
        stmt.bindText(6, cellar_path) catch return InstallError.RecordFailed;
        _ = stmt.step() catch return InstallError.RecordFailed;

        keg_id = getLastInsertId(db) catch return InstallError.RecordFailed;
    }

    linker.link(cellar_path, parts.formula, keg_id) catch {};
    linker.linkOpt(parts.formula, rb.version) catch {};

    db.commit() catch return InstallError.RecordFailed;

    output.success("{s} {s} installed", .{ parts.formula, rb.version });
}

/// Minimal Ruby formula parser for GoReleaser-style formulas.
/// Extracts version, URL, and SHA256 for the current platform.
const RubyFormulaInfo = struct {
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
};

fn parseRubyFormula(rb_content: []const u8) ?RubyFormulaInfo {
    const is_arm = @import("../macho/codesign.zig").isArm64();

    var version: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var sha256: ?[]const u8 = null;

    // State machine: look for the right CPU section
    var in_correct_section = false;
    var in_macos = false;

    var line_start: usize = 0;
    for (rb_content, 0..) |ch, idx| {
        if (ch == '\n' or idx == rb_content.len - 1) {
            const line_end = if (ch == '\n') idx else idx + 1;
            const line = std.mem.trim(u8, rb_content[line_start..line_end], " \t\r");
            line_start = idx + 1;

            // Extract version (global)
            if (version == null) {
                if (extractQuoted(line, "version \"")) |v| {
                    version = v;
                }
            }

            // Track on_macos block
            if (std.mem.indexOf(u8, line, "on_macos") != null) {
                in_macos = true;
            }

            // Track CPU section (Formula style: Hardware::CPU, Cask style: on_arm/on_intel)
            if (in_macos) {
                if (is_arm and (std.mem.indexOf(u8, line, "Hardware::CPU.arm?") != null or
                    std.mem.indexOf(u8, line, "on_arm") != null))
                {
                    in_correct_section = true;
                } else if (!is_arm and (std.mem.indexOf(u8, line, "Hardware::CPU.intel?") != null or
                    std.mem.indexOf(u8, line, "on_intel") != null))
                {
                    in_correct_section = true;
                }
            }

            // Extract URL and SHA256 within the correct section
            if (in_correct_section) {
                if (url == null) {
                    if (extractQuoted(line, "url \"")) |u| {
                        url = u;
                    }
                }
                if (sha256 == null) {
                    if (extractQuoted(line, "sha256 \"")) |s| {
                        sha256 = s;
                    }
                }
            }

            // If we have both, stop
            if (url != null and sha256 != null) break;
        }
    }

    // Fallback: if no CPU-specific section found, try global url/sha256
    if (url == null or sha256 == null) {
        var ls: usize = 0;
        for (rb_content, 0..) |ch, idx| {
            if (ch == '\n' or idx == rb_content.len - 1) {
                const le = if (ch == '\n') idx else idx + 1;
                const ln = std.mem.trim(u8, rb_content[ls..le], " \t\r");
                ls = idx + 1;

                if (url == null) {
                    if (extractQuoted(ln, "url \"")) |u| url = u;
                }
                if (sha256 == null) {
                    if (extractQuoted(ln, "sha256 \"")) |s| sha256 = s;
                }
            }
        }
    }

    if (version != null and url != null and sha256 != null) {
        return .{ .version = version.?, .url = url.?, .sha256 = sha256.? };
    }
    return null;
}

fn extractQuoted(line: []const u8, prefix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, prefix) orelse return null;
    const value_start = start + prefix.len;
    if (value_start >= line.len) return null;
    const end = std.mem.indexOfScalar(u8, line[value_start..], '"') orelse return null;
    return line[value_start .. value_start + end];
}
