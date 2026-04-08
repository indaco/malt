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
    // Check for tap formula format: user/repo/formula
    if (isTapFormula(pkg_name)) {
        return installTapFormula(allocator, pkg_name, db, linker, prefix, dry_run, force);
    }

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
    var formula = formula_mod.parseFormula(allocator, formula_json) catch |e| {
        output.err("Failed to parse formula JSON for '{s}': {s} (json len={d})", .{ pkg_name, @errorName(e), formula_json.len });
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

    // Extract GHCR repo path and digest from the bottle URL.
    // URL format: https://ghcr.io/v2/{repo}/blobs/{digest}
    // e.g. https://ghcr.io/v2/homebrew/core/openssl/3/blobs/sha256:abc...
    var repo_buf: [256]u8 = undefined;
    var digest_buf: [128]u8 = undefined;
    var repo: []const u8 = undefined;
    var digest: []const u8 = undefined;

    const ghcr_prefix = "https://ghcr.io/v2/";
    if (std.mem.startsWith(u8, bottle.url, ghcr_prefix)) {
        const path = bottle.url[ghcr_prefix.len..];
        if (std.mem.indexOf(u8, path, "/blobs/")) |blobs_pos| {
            repo = std.fmt.bufPrint(&repo_buf, "{s}", .{path[0..blobs_pos]}) catch
                return InstallError.DownloadFailed;
            digest = std.fmt.bufPrint(&digest_buf, "{s}", .{path[blobs_pos + "/blobs/".len ..]}) catch
                return InstallError.DownloadFailed;
        } else {
            // Fallback: construct from name (replace @ with /)
            repo = buildGhcrRepo(&repo_buf, formula.name) catch
                return InstallError.DownloadFailed;
            digest = std.fmt.bufPrint(&digest_buf, "sha256:{s}", .{bottle.sha256}) catch
                return InstallError.DownloadFailed;
        }
    } else {
        repo = buildGhcrRepo(&repo_buf, formula.name) catch
            return InstallError.DownloadFailed;
        digest = std.fmt.bufPrint(&digest_buf, "sha256:{s}", .{bottle.sha256}) catch
            return InstallError.DownloadFailed;
    }

    // Create temp dir for extraction
    const tmp_dir = atomic.createTempDir(allocator, formula.name) catch {
        output.err("Failed to create temp directory", .{});
        return InstallError.DownloadFailed;
    };
    // Note: don't defer cleanupTempDir — commitFrom renames it to store.
    // If download/commit fails, errdefer below cleans up.
    errdefer atomic.cleanupTempDir(tmp_dir);
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

    // Step 7: Commit to store (atomic rename from tmp dir)
    output.info("Committing {s} to store...", .{formula.name});
    store.commitFrom(result.sha256, tmp_dir) catch {
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

    output.info("{s} {s} installed successfully", .{ parts.formula, rb.version });
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
