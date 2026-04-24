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
const io_mod = @import("../ui/io.zig");
const codesign = @import("../macho/codesign.zig");
const post_install_mod = @import("install/post_install.zig");
const help = @import("help.zig");

/// Resolve the Homebrew install prefix. Respects `HOMEBREW_PREFIX` (set
/// by `brew shellenv` and by users with a non-standard install), falls
/// back to the arch-based default. Exposed so smoke tests can point the
/// command at a fake Cellar under a scratch path.
pub fn detectBrewPrefix() []const u8 {
    if (fs_compat.getenv("HOMEBREW_PREFIX")) |p| {
        if (p.len > 0) return p;
    }
    return if (codesign.isArm64()) "/opt/homebrew" else "/usr/local";
}

/// Lock-acquire timeout. `MALT_LOCK_TIMEOUT_MS` overrides the 30 s default.
fn lockTimeoutMs() u32 {
    if (fs_compat.getenv("MALT_LOCK_TIMEOUT_MS")) |v| {
        return std.fmt.parseInt(u32, v, 10) catch 30_000;
    }
    return 30_000;
}

/// Arena-own Cellar names and log iterator errors instead of silently
/// truncating the scan — `iter.next() catch null` used to hide every
/// later keg behind the first bad entry. `anytype` for mock iterators.
pub fn scanCellarKegs(
    arena: std.mem.Allocator,
    iter: anytype,
    names: *std.ArrayList([]const u8),
) !void {
    while (true) {
        const entry = iter.next() catch |err| {
            output.warn("Cellar scan error: {s}; keeping {d} entries already found", .{ @errorName(err), names.items.len });
            break;
        } orelse break;
        if (entry.kind != .directory) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
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

/// Named-field bundle for the shared state `migrateKeg` threads across
/// every keg in the loop. Opens a DI seam for tests to swap in fakes.
const MigrateDeps = struct {
    api: *api_mod.BrewApi,
    ghcr: *ghcr_mod.GhcrClient,
    http: *client_mod.HttpClient,
    store: *store_mod.Store,
    linker: *linker_mod.Linker,
    db: *sqlite.Database,
    prefix: []const u8,
    use_system_ruby_scope: []const []const u8,
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "migrate")) return;

    const start_ts = fs_compat.milliTimestamp();
    const json_mode = output.isJson();
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
    const brew_prefix = detectBrewPrefix();
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

    // Uniform scan-lifetime dupes → one arena, no per-entry free plumbing.
    var scan_arena = std.heap.ArenaAllocator.init(allocator);
    defer scan_arena.deinit();
    var keg_names: std.ArrayList([]const u8) = .empty;

    var iter = dir.iterate();
    try scanCellarKegs(scan_arena.allocator(), &iter, &keg_names);

    if (keg_names.items.len == 0) {
        if (json_mode) {
            try emitDryRunJson(allocator, brew_prefix, &.{}, dry_run, start_ts);
        } else {
            output.info("No kegs found in Homebrew Cellar", .{});
        }
        return;
    }

    output.info("Found {d} package(s) in Homebrew Cellar", .{keg_names.items.len});

    // ── Dry-run mode: list and exit ─────────────────────────────────
    if (dry_run) {
        if (json_mode) {
            try emitDryRunJson(allocator, brew_prefix, keg_names.items, true, start_ts);
        } else {
            for (keg_names.items) |name| {
                output.info("  Would migrate: {s}", .{name});
            }
            output.info("Would migrate {d} packages from Homebrew", .{keg_names.items.len});
            output.warn("Run without --dry-run to perform migration", .{});
        }
        return;
    }

    // ── Step 3: Initialize malt infrastructure ──────────────────────
    const prefix = atomic.maltPrefix();
    ensureDirs(prefix) catch return error.Aborted;

    // Open database
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database at {s}", .{db_path});
        return error.Aborted;
    };
    defer db.close();

    schema.initSchema(&db) catch {
        output.err("Failed to initialize database schema", .{});
        return error.Aborted;
    };

    // Acquire lock; `MALT_LOCK_TIMEOUT_MS` tunes the 30 s default.
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk = lock_mod.LockFile.acquire(lock_path, lockTimeoutMs()) catch {
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
    // Per-category name lists: counts are derived lengths; JSON emits arrays verbatim.
    var migrated_names: std.ArrayList([]const u8) = .empty;
    defer migrated_names.deinit(allocator);
    var skipped_installed_names: std.ArrayList([]const u8) = .empty;
    defer skipped_installed_names.deinit(allocator);
    var skipped_post_install_names: std.ArrayList([]const u8) = .empty;
    defer skipped_post_install_names.deinit(allocator);
    var skipped_no_bottle_names: std.ArrayList([]const u8) = .empty;
    defer skipped_no_bottle_names.deinit(allocator);
    var failed_names: std.ArrayList([]const u8) = .empty;
    defer failed_names.deinit(allocator);

    // Honour Ctrl-C raised during setup, before any network work starts.
    const main_mod = @import("../main.zig");
    if (main_mod.isInterrupted()) {
        output.warn("Interrupted before migration.", .{});
        return;
    }

    for (keg_names.items) |keg_name| {
        // Stop at the next keg boundary when the user hits Ctrl-C.
        if (main_mod.isInterrupted()) {
            output.warn("Interrupted — skipping remaining kegs.", .{});
            break;
        }
        const result = migrateKeg(allocator, keg_name, .{
            .api = &api,
            .ghcr = &ghcr,
            .http = &http,
            .store = &store,
            .linker = &linker,
            .db = &db,
            .prefix = prefix,
            .use_system_ruby_scope = use_system_ruby_scope.items,
        });

        // OOM on per-category bookkeeping must not be swallowed: the summary
        // counts and JSON arrays come from these lists, and a silent drop
        // reports fewer failures than actually occurred.
        switch (result) {
            .migrated => try migrated_names.append(allocator, keg_name),
            .skipped_installed => try skipped_installed_names.append(allocator, keg_name),
            .skipped_post_install => try skipped_post_install_names.append(allocator, keg_name),
            .skipped_no_bottle => try skipped_no_bottle_names.append(allocator, keg_name),
            .failed_api, .failed_download, .failed_install => try failed_names.append(allocator, keg_name),
        }
    }

    // ── Step 5: Report ──────────────────────────────────────────────
    if (json_mode) {
        try emitSummaryJson(
            allocator,
            brew_prefix,
            migrated_names.items,
            skipped_installed_names.items,
            skipped_post_install_names.items,
            skipped_no_bottle_names.items,
            failed_names.items,
            start_ts,
        );
        return;
    }

    const migrated: u32 = @intCast(migrated_names.items.len);
    // Preserve legacy lumping: human summary merges installed + no-bottle under "Skipped (installed)".
    const skipped: u32 = @intCast(skipped_installed_names.items.len + skipped_no_bottle_names.items.len);
    const skipped_post_install: u32 = @intCast(skipped_post_install_names.items.len);
    const failed: u32 = @intCast(failed_names.items.len);

    output.info("", .{});
    output.info("Migration complete:", .{});
    output.info("  Migrated:              {d}", .{migrated});
    if (skipped > 0)
        output.info("  Skipped (installed):   {d}", .{skipped});
    if (skipped_post_install > 0) {
        output.warn("  Skipped (post_install): {d}", .{skipped_post_install});
        for (skipped_post_install_names.items) |name| {
            output.warn("    - {s} (needs post_install — use: brew install {s})", .{ name, name });
        }
        // Preserved legacy: no-bottle entries printed under the post_install warning.
        for (skipped_no_bottle_names.items) |name| {
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
    deps: MigrateDeps,
) KegResult {
    // 1. Check if already installed in malt
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

    // 3. Resolve bottle for this platform
    const bottle = formula_mod.resolveBottle(allocator, &formula) catch {
        output.warn("  {s}: no bottle available for this platform", .{keg_name});
        return .skipped_no_bottle;
    };

    output.info("  Migrating {s} {s}...", .{ formula.name, formula.version });

    // 5. Download bottle via GHCR (skip if already in store)
    if (!deps.store.exists(bottle.sha256)) {
        if (!downloadBottle(allocator, deps.ghcr, deps.http, deps.store, bottle.url, bottle.sha256, keg_name)) {
            return .failed_download;
        }
    } else {
        output.info("    {s} (cached in store)", .{keg_name});
    }

    // Increment store refcount
    deps.store.incrementRef(bottle.sha256) catch |e| {
        std.log.warn("refcount increment failed for {s}: {s}", .{ keg_name, @errorName(e) });
    };

    // 6. Materialize to cellar
    const keg = cellar_mod.materialize(
        allocator,
        deps.prefix,
        bottle.sha256,
        formula.name,
        formula.pkg_version,
    ) catch {
        output.err("    {s}: failed to materialize", .{keg_name});
        return .failed_install;
    };

    // 7. Record in DB + link
    if (!formula.keg_only) {
        const keg_id = recordKeg(deps.db, &formula, bottle.sha256, keg.path, "direct") catch {
            output.err("    {s}: failed to record in database", .{keg_name});
            // Rollback: remove materialised keg when DB record fails.
            cellar_mod.remove(deps.prefix, formula.name, formula.pkg_version) catch {};
            return .failed_install;
        };

        deps.linker.link(keg.path, formula.name, keg_id) catch {
            output.warn("    {s}: some links could not be created", .{keg_name});
            // Rollback: unlink partial links and delete keg row; user already warned above.
            deps.linker.unlink(keg_id) catch {};
            deleteKeg(deps.db, keg_id) catch {};
            cellar_mod.remove(deps.prefix, formula.name, formula.pkg_version) catch {};
            return .failed_install;
        };
        // Opt symlink is convenience; install is already functional via versioned link.
        deps.linker.linkOpt(formula.name, formula.pkg_version) catch {};
        recordDeps(deps.db, keg_id, &formula);
    } else {
        const keg_id = recordKeg(deps.db, &formula, bottle.sha256, keg.path, "direct") catch {
            // Rollback: remove materialised keg when DB record fails.
            cellar_mod.remove(deps.prefix, formula.name, formula.pkg_version) catch {};
            return .failed_install;
        };
        // Opt symlink is convenience; install is already functional via versioned link.
        deps.linker.linkOpt(formula.name, formula.pkg_version) catch {};
        recordDeps(deps.db, keg_id, &formula);
    }

    if (formula.post_install_defined) {
        post_install_mod.drive(
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

fn isInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}

// ── JSON output ─────────────────────────────────────────────────────

/// Build + flush the dry-run (or empty-Cellar) JSON document to stdout.
fn emitDryRunJson(
    allocator: std.mem.Allocator,
    brew_prefix: []const u8,
    keg_names: []const []const u8,
    dry_run: bool,
    start_ts: i64,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try buildDryRunJson(&aw.writer, brew_prefix, keg_names, dry_run, start_ts);
    io_mod.stdoutWriteAll(aw.written());
}

/// Build + flush the final-summary JSON document to stdout.
fn emitSummaryJson(
    allocator: std.mem.Allocator,
    brew_prefix: []const u8,
    migrated_names: []const []const u8,
    skipped_installed_names: []const []const u8,
    skipped_post_install_names: []const []const u8,
    skipped_no_bottle_names: []const []const u8,
    failed_names: []const []const u8,
    start_ts: i64,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try buildSummaryJson(
        &aw.writer,
        brew_prefix,
        migrated_names,
        skipped_installed_names,
        skipped_post_install_names,
        skipped_no_bottle_names,
        failed_names,
        start_ts,
    );
    io_mod.stdoutWriteAll(aw.written());
}

/// Dry-run JSON `{dry_run, brew_prefix, kegs, count, time_ms}`; `pub` for direct test assertions.
pub fn buildDryRunJson(
    w: *std.Io.Writer,
    brew_prefix: []const u8,
    keg_names: []const []const u8,
    dry_run: bool,
    start_ts: i64,
) !void {
    try w.writeAll("{\"dry_run\":");
    try w.writeAll(if (dry_run) "true" else "false");
    try w.writeAll(",\"brew_prefix\":");
    try output.jsonStr(w, brew_prefix);
    try w.writeAll(",\"kegs\":");
    try output.jsonStringArray(w, keg_names);
    var tail: [64]u8 = undefined;
    const tail_str = try std.fmt.bufPrint(&tail, ",\"count\":{d}", .{keg_names.len});
    try w.writeAll(tail_str);
    try output.jsonTimeSuffix(w, start_ts);
    try w.writeAll("}\n");
}

/// Final-summary JSON: per-category arrays + counts + time_ms; `pub` for direct test assertions.
pub fn buildSummaryJson(
    w: *std.Io.Writer,
    brew_prefix: []const u8,
    migrated_names: []const []const u8,
    skipped_installed_names: []const []const u8,
    skipped_post_install_names: []const []const u8,
    skipped_no_bottle_names: []const []const u8,
    failed_names: []const []const u8,
    start_ts: i64,
) !void {
    try w.writeAll("{\"dry_run\":false,\"brew_prefix\":");
    try output.jsonStr(w, brew_prefix);
    try w.writeAll(",\"migrated\":");
    try output.jsonStringArray(w, migrated_names);
    try w.writeAll(",\"skipped_installed\":");
    try output.jsonStringArray(w, skipped_installed_names);
    try w.writeAll(",\"skipped_post_install\":");
    try output.jsonStringArray(w, skipped_post_install_names);
    try w.writeAll(",\"skipped_no_bottle\":");
    try output.jsonStringArray(w, skipped_no_bottle_names);
    try w.writeAll(",\"failed\":");
    try output.jsonStringArray(w, failed_names);
    var counts_buf: [256]u8 = undefined;
    const counts = try std.fmt.bufPrint(
        &counts_buf,
        ",\"counts\":{{\"migrated\":{d},\"skipped_installed\":{d},\"skipped_post_install\":{d},\"skipped_no_bottle\":{d},\"failed\":{d}}}",
        .{
            migrated_names.len,
            skipped_installed_names.len,
            skipped_post_install_names.len,
            skipped_no_bottle_names.len,
            failed_names.len,
        },
    );
    try w.writeAll(counts);
    try output.jsonTimeSuffix(w, start_ts);
    try w.writeAll("}\n");
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
