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
const store_mod = @import("../core/store.zig");
const linker_mod = @import("../core/linker.zig");
const client_mod = @import("../net/client.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const api_mod = @import("../net/api.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const io_mod = @import("../ui/io.zig");
const codesign = @import("../macho/codesign.zig");
const help = @import("help.zig");
const keg_mod = @import("migrate/keg.zig");
const manifest_mod = @import("migrate/manifest.zig");
const parallel_mod = @import("migrate/parallel.zig");

const KegResult = keg_mod.KegResult;
const MigrateDeps = keg_mod.MigrateDeps;
const migrateKeg = keg_mod.migrateKeg;

/// Test seam — pins dispatch decisions without relying on observable
/// side-effects. Reset on every `execute` entry.
pub var last_run_parallel: bool = false;

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

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "migrate")) return;

    last_run_parallel = false;

    const start_ts = fs_compat.milliTimestamp();
    const json_mode = output.isJson();
    var dry_run = output.isDryRun();
    // Ruby is opt-in per keg only. A bare --use-system-ruby across a
    // whole `migrate` would widen the trust boundary to every
    // Homebrew-Cellar entry at once; refuse it and require names.
    var use_system_ruby_bare = false;
    var parallel_flag = false;
    var use_system_ruby_scope: std.ArrayList([]const u8) = .empty;
    defer use_system_ruby_scope.deinit(allocator);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) dry_run = true;
        if (std.mem.eql(u8, arg, "--parallel")) parallel_flag = true;
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
        // Per-keg plan event — consumers don't need to parse the
        // human/--json blob to pre-flight a migration.
        if (output.isNdjson()) {
            for (keg_names.items) |kn| {
                output.emitNdjsonEvent(allocator, .would_install, kn, null);
            }
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
    // LIFO: install_complete fires before lk.release. Inline gate keeps
    // the deferred call out of the default paths.
    defer if (output.isNdjson()) output.emitNdjsonEvent(allocator, .install_complete, "", null);
    output.emitNdjsonEvent(allocator, .lock_acquired, "", null);

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

    // Resume manifest: a crashed/^C run resumes from where it stopped
    // instead of redoing every keg.
    var manifest_path_buf: [512]u8 = undefined;
    const manifest_path = std.fmt.bufPrint(
        &manifest_path_buf,
        "{s}/cache/migrate.progress.json",
        .{prefix},
    ) catch return;
    var manifest = manifest_mod.loadFromPath(allocator, manifest_path) catch |e| blk: {
        output.warn("Could not read resume manifest ({s}); starting fresh", .{@errorName(e)});
        break :blk manifest_mod.Manifest.init(allocator);
    };
    defer manifest.deinit();

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

    if (parallel_flag) {
        last_run_parallel = true;

        const worker_count = parallel_mod.boundWorkerCount(
            parallel_mod.workerCountFromLiveEnv(),
            keg_names.items.len,
        );

        // Borrowed clients keep TLS contexts warm across kegs without
        // paying a fresh handshake per worker.
        var http_pool = client_mod.HttpClientPool.init(allocator, @intCast(@max(worker_count, 1))) catch {
            output.err("Failed to initialise HTTP client pool", .{});
            return error.Aborted;
        };
        defer http_pool.deinit();

        var db_mu: std.Io.Mutex = .init;
        var manifest_mu: std.Io.Mutex = .init;

        const outcomes = try allocator.alloc(parallel_mod.KegOutcome, keg_names.items.len);
        defer allocator.free(outcomes);
        // Pre-populated so an interrupted/short-circuited slot still has a defined outcome.
        for (outcomes, 0..) |*o, i| o.* = .{ .name = keg_names.items[i], .result = .skipped_installed };

        var pool: parallel_mod.Pool = .{
            .next_idx = std.atomic.Value(usize).init(0),
            .keg_names = keg_names.items,
            .outcomes = outcomes,
            .cache_dir = cache_dir,
            .prefix = prefix,
            .use_system_ruby_scope = use_system_ruby_scope.items,
            .http_pool = &http_pool,
            .store = &store,
            .linker = &linker,
            .db = &db,
            .db_mu = &db_mu,
            .manifest = &manifest,
            .manifest_mu = &manifest_mu,
            .manifest_path = manifest_path,
            .manifest_allocator = allocator,
        };
        try parallel_mod.run(allocator, &pool, worker_count);
        // Mirror the serial loop's interrupt UX so users running with
        // --parallel still see "Interrupted" instead of silent skips.
        if (main_mod.isInterrupted()) {
            output.warn("Interrupted — skipping remaining kegs.", .{});
        }

        for (outcomes) |o| {
            switch (o.result) {
                .migrated => try migrated_names.append(allocator, o.name),
                .skipped_installed => try skipped_installed_names.append(allocator, o.name),
                .skipped_post_install => try skipped_post_install_names.append(allocator, o.name),
                .skipped_no_bottle => try skipped_no_bottle_names.append(allocator, o.name),
                .failed_api, .failed_download, .failed_install => try failed_names.append(allocator, o.name),
            }
        }
    } else for (keg_names.items) |keg_name| {
        // Stop at the next keg boundary when the user hits Ctrl-C.
        if (main_mod.isInterrupted()) {
            output.warn("Interrupted — skipping remaining kegs.", .{});
            break;
        }
        // Resume short-circuit before any API/network work — bounds
        // re-runs by the remaining kegs, not the full set. The DB
        // cross-check guards against a stale manifest after `mt
        // uninstall`: manifest=yes / DB=no falls through to a real
        // re-migrate instead of silently skipping a missing keg.
        if (manifest.contains(keg_name) and keg_mod.isInstalled(&db, keg_name)) {
            try skipped_installed_names.append(allocator, keg_name);
            continue;
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
            .migrated => {
                try migrated_names.append(allocator, keg_name);
                // Persist after each success so a crash leaves the next
                // run with the smallest possible to-do list.
                manifest.add(keg_name) catch |e| {
                    output.warn("Resume manifest update failed for {s}: {s}", .{ keg_name, @errorName(e) });
                };
                manifest.writeAtomic(allocator, manifest_path) catch |e| {
                    output.warn("Resume manifest write failed: {s}", .{@errorName(e)});
                };
            },
            .skipped_installed => try skipped_installed_names.append(allocator, keg_name),
            .skipped_post_install => try skipped_post_install_names.append(allocator, keg_name),
            .skipped_no_bottle => try skipped_no_bottle_names.append(allocator, keg_name),
            .failed_api, .failed_download, .failed_install => try failed_names.append(allocator, keg_name),
        }
    }

    // Self-heal the resume manifest: any DB-confirmed skip that wasn't
    // already recorded gets added now, so a SIGKILL between "DB
    // committed" and "manifest writeAtomic flushed" converges on the
    // next run instead of paying the DB-lookup penalty forever.
    var manifest_dirty = false;
    for (skipped_installed_names.items) |name| {
        if (!manifest.contains(name)) {
            manifest.add(name) catch continue;
            manifest_dirty = true;
        }
    }
    if (manifest_dirty) {
        manifest.writeAtomic(allocator, manifest_path) catch |e| {
            output.warn("Resume manifest self-heal write failed: {s}", .{@errorName(e)});
        };
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
