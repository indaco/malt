//! malt — migrate command
//! Import existing Homebrew installation.
//! Scans the Homebrew Cellar, resolves each keg via the Homebrew API,
//! downloads bottles through GHCR, and installs them via malt's atomic
//! install protocol. Never modifies the Homebrew installation.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const linker_mod = @import("../core/linker.zig");
const signals = @import("../core/signals.zig");
const store_mod = @import("../core/store.zig");
const lock_mod = @import("../db/lock.zig");
const lock_report = @import("lock_report.zig");
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const codesign = @import("../macho/codesign.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
const progress_mod = @import("../ui/progress.zig");
const help = @import("help.zig");
const keg_mod = @import("migrate/keg.zig");
const KegResult = keg_mod.KegResult;
const MigrateDeps = keg_mod.MigrateDeps;
const migrateKeg = keg_mod.migrateKeg;
const manifest_mod = @import("migrate/manifest.zig");
const outcomes_mod = @import("migrate/outcomes.zig");
const parallel_mod = @import("migrate/parallel.zig");
const post_install_queue_mod = @import("migrate/post_install_queue.zig");

/// Test seam — pins dispatch decisions without relying on observable
/// side-effects. Reset on every `execute` entry.
pub var last_run_parallel: bool = false;

/// Resolve the Homebrew install prefix. Respects `HOMEBREW_PREFIX` (set
/// by `brew shellenv` and by users with a non-standard install), falls
/// back to the arch-based default. Exposed so smoke tests can point the
/// command at a fake Cellar under a scratch path.
pub fn detectBrewPrefix(ctx: *const AppCtx) []const u8 {
    if (std.process.Environ.getPosix(ctx.environ, "HOMEBREW_PREFIX")) |p| {
        if (p.len > 0) return p;
    }
    return if (codesign.isArm64()) "/opt/homebrew" else "/usr/local";
}

/// Lock-acquire timeout. `MALT_LOCK_TIMEOUT_MS` overrides the 30 s default.
fn lockTimeoutMs(ctx: *const AppCtx) u32 {
    if (std.process.Environ.getPosix(ctx.environ, "MALT_LOCK_TIMEOUT_MS")) |v| {
        return std.fmt.parseInt(u32, v, 10) catch 30_000;
    }
    return 30_000;
}

/// Arena-own Cellar names and log + skip iterator errors instead of
/// truncating the scan — `iter.next() catch null` used to hide every
/// later keg behind the first bad entry. `anytype` for mock iterators
/// and a duck-typed `dir` so symlink-target lookups go through the same
/// `Dir.statFile` shape in production and in tests.
pub fn scanCellarKegs(
    io: std.Io,
    arena: std.mem.Allocator,
    iter: anytype,
    dir: anytype,
    names: *std.ArrayList([]const u8),
) !void {
    while (true) {
        const entry = iter.next(io) catch |err| {
            output.warn("Cellar scan error: {s}; skipping entry, kept {d} so far", .{ @errorName(err), names.items.len });
            continue;
        } orelse break;
        const accept = switch (entry.kind) {
            .directory => true,
            // Resolve the symlink target; dangling or non-dir links
            // fall through the silent-skip path the rest of the scan uses.
            .sym_link => blk: {
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = true }) catch
                    break :blk false;
                break :blk stat.kind == .directory;
            },
            else => false,
        };
        if (!accept) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "migrate")) return;

    last_run_parallel = false;

    const start_ts = std.Io.Clock.real.now(ctx.io).toMilliseconds();
    const json_mode = output.isJson();
    // Under `--json`, embed per-keg post_install events in the summary
    // doc rather than streaming each as a JSONL line.
    if (json_mode) output.setPostInstallEmit(.embed, allocator);
    defer output.resetPostInstallEvents();
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
    const brew_prefix = detectBrewPrefix(ctx);
    var cellar_buf: [256]u8 = undefined;
    const brew_cellar = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{brew_prefix}) catch return;

    std.Io.Dir.accessAbsolute(ctx.io, brew_cellar, .{}) catch {
        output.err("No Homebrew installation found at {s}", .{brew_prefix});
        return error.Aborted;
    };

    output.info("Found Homebrew installation at {s}", .{brew_prefix});

    // ── Step 2: Scan Cellar for installed kegs ──────────────────────
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, brew_cellar, .{ .iterate = true }) catch {
        output.err("Cannot read Homebrew Cellar", .{});
        return error.Aborted;
    };
    defer dir.close(ctx.io);

    // Uniform scan-lifetime dupes → one arena, no per-entry free plumbing.
    var scan_arena = std.heap.ArenaAllocator.init(allocator);
    defer scan_arena.deinit();
    var keg_names: std.ArrayList([]const u8) = .empty;

    var iter = dir.iterate();
    try scanCellarKegs(ctx.io, scan_arena.allocator(), &iter, &dir, &keg_names);

    if (keg_names.items.len == 0) {
        if (json_mode) {
            // One document shape per mode, regardless of count: dry-run
            // keeps the `kegs`/`count` payload, real run emits the
            // summary shape with empty arrays.
            if (dry_run) {
                try emitDryRunJson(allocator, brew_prefix, &.{}, true, start_ts);
            } else {
                try emitSummaryJson(
                    allocator,
                    brew_prefix,
                    &.{},
                    &.{},
                    &.{},
                    &.{},
                    &.{},
                    &.{},
                    start_ts,
                );
            }
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
                output.emitNdjsonEvent(.would_install, kn, null);
            }
        }
        return;
    }

    // ── Step 3: Initialize malt infrastructure ──────────────────────
    const prefix = atomic.maltPrefixOrAbort();
    ensureDirs(ctx, prefix) catch return error.Aborted;

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
    var lk = lock_mod.LockFile.acquire(ctx.io, lock_path, lockTimeoutMs(ctx)) catch |e| switch (e) {
        // The DB is already open here, so db/ exists — DirMissing can't occur.
        error.DirMissing => return error.Aborted,
        else => {
            lock_report.reportAcquireFailure(e, prefix);
            return error.Aborted;
        },
    };
    defer lk.release(ctx.io);
    // LIFO: install_complete fires before lk.release. Inline gate keeps
    // the deferred call out of the default paths.
    defer if (output.isNdjson()) output.emitNdjsonEvent(.install_complete, "", null);
    output.emitNdjsonEvent(.lock_acquired, "", null);

    // Set up HTTP + API + GHCR + store + linker
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    http.offline = ctx.offline;

    var cache_dir_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_dir_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(ctx.io, allocator, &http, cache_dir);
    api.base_url = ctx.mirrors.api_base;
    api.offline = ctx.offline;

    var ghcr = ghcr_mod.GhcrClient.init(ctx.io, allocator, &http);
    ghcr.base_url = ctx.mirrors.bottle_base;
    defer ghcr.deinit();

    var store = store_mod.Store.init(ctx.io, allocator, &db, prefix);
    var linker = linker_mod.Linker.init(ctx.io, allocator, &db, prefix);

    // Resume manifest: a crashed/^C run resumes from where it stopped
    // instead of redoing every keg.
    var manifest_path_buf: [512]u8 = undefined;
    const manifest_path = std.fmt.bufPrint(
        &manifest_path_buf,
        "{s}/cache/migrate.progress.json",
        .{prefix},
    ) catch return;
    var manifest = manifest_mod.loadFromPath(ctx, allocator, manifest_path) catch |e| blk: {
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
    var cancelled_names: std.ArrayList([]const u8) = .empty;
    defer cancelled_names.deinit(allocator);

    // One drain target both arms share so the six-way KegResult
    // categorization lives at a single site.
    const buckets: outcomes_mod.Buckets = .{
        .migrated = &migrated_names,
        .skipped_installed = &skipped_installed_names,
        .skipped_post_install = &skipped_post_install_names,
        .skipped_no_bottle = &skipped_no_bottle_names,
        .failed = &failed_names,
        .cancelled = &cancelled_names,
    };

    // Honour Ctrl-C raised during setup, before any network work starts.
    if (signals.isInterrupted()) {
        output.warn("Interrupted before migration.", .{});
        return;
    }

    // Defer every keg's post_install until all kegs are materialised
    // and `linkOpt`'d, so a hook subprocess (e.g. fc-cache) can
    // resolve dep dylibs through `opt/<dep>` without racing the
    // worker that links them.
    var post_install_queue = post_install_queue_mod.Queue.init(allocator);
    defer post_install_queue.deinit();

    if (parallel_flag) {
        last_run_parallel = true;
        try parallel_mod.runMigration(allocator, .{
            .app_ctx = ctx,
            .keg_names = keg_names.items,
            .cache_dir = cache_dir,
            .prefix = prefix,
            .homebrew_prefix = brew_prefix,
            .use_system_ruby_scope = use_system_ruby_scope.items,
            .store = &store,
            .linker = &linker,
            .db = &db,
            .manifest = &manifest,
            .manifest_path = manifest_path,
            .post_install_queue = &post_install_queue,
        }, buckets);
    } else {
        // Width of the widest keg name so per-keg bars line up vertically
        // with each other (and with `install`'s download phase).
        const max_name_len = outcomes_mod.maxNameLen(keg_names.items);

        for (keg_names.items) |keg_name| {
            // Stop at the next keg boundary when the user hits Ctrl-C.
            if (signals.isInterrupted()) {
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

            // One-line group so the bar inherits autowrap-off + restore.
            // Initial frame so the row isn't blank before the first
            // progress callback fires.
            var sp = progress_mod.SingleBar.init(keg_name, 0);
            defer sp.finish();
            const bar = sp.bind();
            bar.label_width = max_name_len;
            bar.update(0);

            const result = migrateKeg(ctx, allocator, keg_name, .{
                .api = &api,
                .ghcr = &ghcr,
                .http = &http,
                .store = &store,
                .linker = &linker,
                .db = &db,
                .prefix = prefix,
                .homebrew_prefix = brew_prefix,
                .use_system_ruby_scope = use_system_ruby_scope.items,
                .post_install_queue = &post_install_queue,
                .bar = bar,
            });
            bar.finish();

            // Persist after each success so a crash leaves the next run with
            // the smallest possible to-do list. Hoisted out of the drain so
            // categorization stays pure; the parallel path persists in-worker.
            if (result == .migrated) {
                manifest.add(keg_name) catch |e| {
                    output.warn("Resume manifest update failed for {s}: {s}", .{ keg_name, @errorName(e) });
                };
                manifest.writeAtomic(ctx.io, allocator, manifest_path) catch |e| {
                    output.warn("Resume manifest write failed: {s}", .{@errorName(e)});
                };
            }
            // OOM on per-category bookkeeping must not be swallowed: the summary
            // counts and JSON arrays come from these lists, and a silent drop
            // reports fewer failures than actually occurred.
            try buckets.record(allocator, keg_name, result);
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
        manifest.writeAtomic(ctx.io, allocator, manifest_path) catch |e| {
            output.warn("Resume manifest self-heal write failed: {s}", .{@errorName(e)});
        };
    }

    // Run post_install in enqueue order now that every dep is on disk
    // and linked under `opt/`, so dyld in any spawned subprocess sees a
    // complete tree.
    post_install_queue.drain(ctx, prefix, use_system_ruby_scope.items);

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
            cancelled_names.items,
            start_ts,
        );
        return;
    }

    const migrated: u32 = @intCast(migrated_names.items.len);
    // Preserve legacy lumping: human summary merges installed + no-bottle under "Skipped (installed)".
    const skipped: u32 = @intCast(skipped_installed_names.items.len + skipped_no_bottle_names.items.len);
    const skipped_post_install: u32 = @intCast(skipped_post_install_names.items.len);
    const failed: u32 = @intCast(failed_names.items.len);
    const cancelled: u32 = @intCast(cancelled_names.items.len);

    output.plain("", .{});
    if (failed == 0) {
        output.success("Migration completed.", .{});
    } else {
        output.info("Migration completed.", .{});
    }
    output.info("Migrated: {d}", .{migrated});
    if (skipped > 0)
        output.info("Skipped (installed): {d}", .{skipped});
    if (cancelled > 0)
        output.info("Cancelled: {d}", .{cancelled});
    if (skipped_post_install > 0) {
        output.warn("Skipped (post_install): {d}", .{skipped_post_install});
        for (skipped_post_install_names.items) |name| {
            output.warn("  - {s} (needs post_install — use: brew install {s})", .{ name, name });
        }
        // Preserved legacy: no-bottle entries printed under the post_install warning.
        for (skipped_no_bottle_names.items) |name| {
            output.warn("  - {s} (needs post_install — use: brew install {s})", .{ name, name });
        }
    }
    if (failed > 0) {
        output.err("Failed: {d}", .{failed});
        for (failed_names.items) |name| {
            output.err("  - {s}", .{name});
        }
    }

    if (migrated > 0 and !output.isQuiet()) {
        try emitBrewUninstallHint(allocator, migrated_names.items);
    }
}

/// Emit a follow-up hint listing every successfully migrated keg as a
/// single `brew uninstall …` line. Both lines use the same `  ▸ `
/// prefix + dim color as the version notifier so the trailing block
/// reads as one consistent footer. The body is built manually because
/// the joined name list can exceed `output.dim`'s 4 KiB internal
/// buffer on installs with hundreds of kegs.
fn emitBrewUninstallHint(
    allocator: std.mem.Allocator,
    migrated_names: []const []const u8,
) !void {
    output.plain("", .{});
    output.dim("You can remove the migrated packages from Homebrew with:", .{});

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    const use_color = color.isColorEnabled();
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  ▸ " else "  > ";
    if (use_color) try line.appendSlice(allocator, color.SemanticStyle.detail.code());
    try line.appendSlice(allocator, prefix);
    try line.appendSlice(allocator, "brew uninstall");
    for (migrated_names) |name| {
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, name);
    }
    if (use_color) try line.appendSlice(allocator, color.Style.reset.code());
    try line.append(allocator, '\n');

    output.writeStderrAll(line.items);
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
    output.writeStdoutAll(aw.written());
}

/// Build + flush the final-summary JSON to stdout. Drains the
/// post_install accumulator so per-keg events embed in the summary.
fn emitSummaryJson(
    allocator: std.mem.Allocator,
    brew_prefix: []const u8,
    migrated_names: []const []const u8,
    skipped_installed_names: []const []const u8,
    skipped_post_install_names: []const []const u8,
    skipped_no_bottle_names: []const []const u8,
    failed_names: []const []const u8,
    cancelled_names: []const []const u8,
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
        cancelled_names,
        output.drainPostInstallEvents(),
        start_ts,
    );
    output.writeStdoutAll(aw.written());
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

/// Final-summary JSON: per-category arrays + counts + time_ms; `pub`
/// for direct test assertions. `post_install_events` is embedded
/// verbatim so the per-keg shape stays byte-equivalent to the
/// `--ndjson` line each keg would have streamed.
pub fn buildSummaryJson(
    w: *std.Io.Writer,
    brew_prefix: []const u8,
    migrated_names: []const []const u8,
    skipped_installed_names: []const []const u8,
    skipped_post_install_names: []const []const u8,
    skipped_no_bottle_names: []const []const u8,
    failed_names: []const []const u8,
    cancelled_names: []const []const u8,
    post_install_events: []const []const u8,
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
    try w.writeAll(",\"cancelled\":");
    try output.jsonStringArray(w, cancelled_names);
    try w.writeAll(",\"post_install_events\":[");
    for (post_install_events, 0..) |entry, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(entry);
    }
    try w.writeAll("]");
    var counts_buf: [320]u8 = undefined;
    const counts = try std.fmt.bufPrint(
        &counts_buf,
        ",\"counts\":{{\"migrated\":{d},\"skipped_installed\":{d},\"skipped_post_install\":{d},\"skipped_no_bottle\":{d},\"failed\":{d},\"cancelled\":{d}}}",
        .{
            migrated_names.len,
            skipped_installed_names.len,
            skipped_post_install_names.len,
            skipped_no_bottle_names.len,
            failed_names.len,
            cancelled_names.len,
        },
    );
    try w.writeAll(counts);
    try output.jsonTimeSuffix(w, start_ts);
    try w.writeAll("}\n");
}

/// Ensure all required directories under prefix exist.
fn ensureDirs(ctx: *const AppCtx, prefix: []const u8) !void {
    std.Io.Dir.createDirAbsolute(ctx.io, prefix, .default_dir) catch |e| switch (e) {
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
        std.Io.Dir.createDirAbsolute(ctx.io, dir_path, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => continue,
        };
    }
}
