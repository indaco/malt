//! Per-keg migrate work + supporting DB helpers. Mirrors the
//! `cli/install/{download,record}.zig` split: keep the wide-args
//! per-item function out of the orchestrator so the entry-point file
//! shrinks to flag parsing, scan, and dispatch.

const std = @import("std");

const AppCtx = @import("../../app_ctx.zig").AppCtx;
const bottle_mod = @import("../../core/bottle.zig");
const cellar_mod = @import("../../core/cellar.zig");
const formula_mod = @import("../../core/formula.zig");
const install_receipt_mod = @import("../../core/install_receipt.zig");
const linker_mod = @import("../../core/linker.zig");
const store_mod = @import("../../core/store.zig");
const sqlite = @import("../../db/sqlite.zig");
const atomic = @import("../../fs/atomic.zig");
const api_mod = @import("../../net/api.zig");
const client_mod = @import("../../net/client.zig");
const ghcr_mod = @import("../../net/ghcr.zig");
const output = @import("../../ui/output.zig");
const progress_mod = @import("../../ui/progress.zig");
const post_install_mod = @import("../install/post_install.zig");
const record = @import("../install/record.zig");
const install_sink_mod = @import("../install/sink.zig");
const post_install_queue_mod = @import("post_install_queue.zig");

/// Width budget for the "<tap>/<keg_name>" qualifier we record in
/// `kegs.full_name`. Long org/tap pairs in private taps push past
/// 256 bytes; silently dropping the qualifier on overflow breaks
/// later `mt info <tap>/<name>` and uninstall-by-full-name lookups.
/// Sized like every other path buffer in this module.
const full_name_buf_len = 512;

/// Result of migrating a single keg. `cancelled` marks slots a worker
/// never reached because SIGINT raced ahead — distinct from
/// `skipped_installed` (the keg was already migrated).
pub const KegResult = enum {
    migrated,
    skipped_installed,
    skipped_post_install,
    skipped_no_bottle,
    failed_api,
    failed_download,
    failed_install,
    cancelled,
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
    /// When non-null, download progress streams into this bar (matching
    /// the install-side TUI) and the per-keg "Migrating…"/"migrated"
    /// info/success lines are suppressed so the bar isn't mangled by
    /// interleaved stderr writes. Caller owns lifetime + finish().
    bar: ?*progress_mod.ProgressBar = null,
};

/// `progressBridge`-compatible callback for `bottle_mod.download`. Same
/// shape as the install-side bridge in `cli/install/download.zig`: first
/// report seeds `total` from Content-Length, subsequent reports clamp
/// `current` so a compressed-vs-uncompressed length drift doesn't push
/// the bar past 100%.
fn migrateBarBridge(ctx: *anyopaque, bytes_so_far: u64, content_length: ?u64) void {
    const bar: *progress_mod.ProgressBar = @ptrCast(@alignCast(ctx));
    if (content_length) |total| {
        if (bar.total == 0) bar.total = total;
    }
    const clamped = if (bar.total > 0) @min(bytes_so_far, bar.total) else bytes_so_far;
    bar.update(clamped);
}

/// Migrate a single keg from Homebrew into malt.
pub fn migrateKeg(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    keg_name: []const u8,
    deps: MigrateDeps,
) KegResult {
    // Suppress per-keg info/success only when the bar is *actually*
    // drawing (TTY) — otherwise CI / piped-output users would lose
    // every per-keg signal between the initial scan and the final
    // summary. `is_tty` is captured at bar init via `supportsAnsi`.
    const has_bar = if (deps.bar) |b| b.is_tty else false;

    if (isInstalled(deps.db, keg_name)) {
        if (!has_bar) output.info("  {s}: already installed, skipping", .{keg_name});
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

    const bottle = formula_mod.resolveBottle(&formula) catch {
        output.warn("  {s}: no bottle available for this platform", .{keg_name});
        return .skipped_no_bottle;
    };
    output.emitNdjsonEvent(.resolved, keg_name, null);

    if (!has_bar) output.info("  Migrating {s} {s}...", .{ formula.name, formula.version });

    if (!deps.store.exists(bottle.sha256)) {
        if (!downloadBottle(ctx, allocator, deps.ghcr, deps.http, deps.store, bottle.url, bottle.sha256, keg_name, deps.bar)) {
            return .failed_download;
        }
    } else if (!has_bar) {
        output.info("    {s} (cached in store)", .{keg_name});
    }
    if (output.isNdjson()) {
        output.emitNdjsonEvent(.downloaded, keg_name, "ok");
        output.emitNdjsonEvent(.extracted, keg_name, "ok");
        output.emitNdjsonEvent(.stored, keg_name, "ok");
    }

    // Serialise the refcount bump on the shared connection's write lock
    // before materialise (the expensive step stays parallel, lock-free).
    incrementRefLocked(ctx.io, deps.store, deps.db_mu, bottle.sha256, keg_name);

    const keg = cellar_mod.materialize(
        ctx.io,
        allocator,
        deps.prefix,
        bottle.sha256,
        formula.name,
        formula.pkg_version,
    ) catch {
        output.err("    {s}: failed to materialize", .{keg_name});
        output.emitNdjsonEvent(.materialized, keg_name, "failed");
        return .failed_install;
    };
    output.emitNdjsonEvent(.materialized, keg_name, "ok");

    // Workers serialise on `db_mu` so transactions can't interleave;
    // serial callers leave `db_mu` null and pay no lock cost. The
    // `db_mu_unlocked` flag lets the OOM-fallback path release the
    // lock early (so the inline Ruby subprocess doesn't stall every
    // other worker) without the deferred unlock double-firing.
    var db_mu_unlocked = false;
    if (deps.db_mu) |m| m.lockUncancelable(ctx.io);
    defer if (deps.db_mu) |m| if (!db_mu_unlocked) m.unlock(ctx.io);

    if (!formula.keg_only) {
        const keg_id = record.recordKeg(deps.db, &formula, bottle.sha256, keg.path, "direct", false, .{}) catch {
            output.err("    {s}: failed to record in database", .{keg_name});
            cellar_mod.remove(ctx.io, deps.prefix, formula.name, formula.pkg_version) catch {};
            return .failed_install;
        };

        deps.linker.link(keg.path, formula.name, keg_id, false) catch {
            output.warn("    {s}: some links could not be created", .{keg_name});
            output.emitNdjsonEvent(.linked, keg_name, "failed");
            // Rollback: unlink partial links and delete keg row; user already warned above.
            deps.linker.unlink(keg_id) catch {};
            deleteKeg(deps.db, keg_id) catch {};
            cellar_mod.remove(ctx.io, deps.prefix, formula.name, formula.pkg_version) catch {};
            return .failed_install;
        };
        // `recorded` after both succeed — link rollback above undoes
        // the keg row, so an early emit would lie if link fails.
        output.emitNdjsonEvent(.linked, keg_name, "ok");
        output.emitNdjsonEvent(.recorded, keg_name, "ok");
        deps.linker.linkOpt(formula.name, formula.pkg_version) catch |e| {
            output.warn("opt link for {s} failed: {s} — dependents may fail to load at runtime", .{ formula.name, @errorName(e) });
        };
        recordDeps(deps.db, keg_id, &formula);
    } else {
        const keg_id = record.recordKeg(deps.db, &formula, bottle.sha256, keg.path, "direct", false, .{}) catch {
            cellar_mod.remove(ctx.io, deps.prefix, formula.name, formula.pkg_version) catch {};
            return .failed_install;
        };
        output.emitNdjsonEvent(.recorded, keg_name, "ok");
        deps.linker.linkOpt(formula.name, formula.pkg_version) catch |e| {
            output.warn("opt link for {s} failed: {s} — dependents may fail to load at runtime", .{ formula.name, @errorName(e) });
        };
        recordDeps(deps.db, keg_id, &formula);
    }

    if (formula.hasPostInstallHook()) {
        if (deps.post_install_queue) |q| {
            // Queue dupes the strings so the worker's per-iteration
            // arena is free to die before drain runs.
            q.add(ctx.io, formula.name, formula.pkg_version, formula_json) catch |e| {
                output.warn("    {s}: failed to queue post_install ({s}); running inline", .{ formula.name, @errorName(e) });
                db_mu_unlocked = releaseDbMuForOomFallback(ctx.io, deps.db_mu);
                post_install_mod.drive(
                    ctx,
                    allocator,
                    formula.name,
                    formula.pkg_version,
                    formula_json,
                    deps.prefix,
                    deps.use_system_ruby_scope,
                    null,
                    install_sink_mod.terminal,
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
                null,
                install_sink_mod.terminal,
            );
        }
    }

    if (!has_bar) {
        const keg_only_suffix: []const u8 = if (formula.keg_only) " (keg-only — dependency only)" else "";
        output.success("  {s} {s} migrated{s}", .{ formula.name, formula.version, keg_only_suffix });
    }
    return .migrated;
}

/// Copy-from-Cellar fallback for kegs the brew API can't resolve. Locates
/// `<homebrew_prefix>/Cellar/<name>/`, picks the version subdir whose
/// `INSTALL_RECEIPT.json` mtime is newest (matches brew's "current" version
/// when multiples are present), reads the receipt, and copies the keg tree
/// into malt's Cellar via the same relocation pipeline the bottle path uses.
///
/// This covers two cases that both reach here only on a clean `NotFound`:
/// private/third-party taps (never in the API), and `homebrew/core` kegs
/// renamed/aliased/removed upstream (e.g. `sdl2`, now an alias of
/// `sdl2-compat`). A clean 404 is *not* an outage — outages surface as
/// `ApiUnreachable` and never reach this fallback — so the locally-installed
/// keg is the authoritative artifact to migrate, whatever its tap.
fn migrateFromLocalCellar(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    keg_name: []const u8,
    deps: MigrateDeps,
) KegResult {
    const has_bar = if (deps.bar) |b| b.is_tty else false;
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

    if (receipt.version.len == 0) {
        output.err("  {s}: INSTALL_RECEIPT.json has no source.versions.stable", .{keg_name});
        return .failed_api;
    }

    if (!has_bar) output.info("  Migrating {s} {s} (from {s} tap)...", .{ keg_name, receipt.version, receipt.tap });

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

    var full_name_buf: [full_name_buf_len]u8 = undefined;
    const full_name = std.fmt.bufPrint(&full_name_buf, "{s}/{s}", .{ receipt.tap, keg_name }) catch keg_name;

    const keg_id = record.recordKegFields(deps.db, .{
        .name = keg_name,
        .full_name = full_name,
        .version = receipt.version,
        .revision = 0,
        .tap = receipt.tap,
        .store_sha256 = "",
        .cellar_path = keg.path,
        .install_reason = "direct",
        .bin_isolated = false,
    }, .{}) catch {
        output.err("    {s}: failed to record in database", .{keg_name});
        cellar_mod.remove(ctx.io, deps.prefix, keg_name, receipt.version) catch {};
        return .failed_install;
    };

    deps.linker.link(keg.path, keg_name, keg_id, false) catch {
        output.warn("    {s}: some links could not be created", .{keg_name});
        deps.linker.unlink(keg_id) catch {};
        deleteKeg(deps.db, keg_id) catch {};
        cellar_mod.remove(ctx.io, deps.prefix, keg_name, receipt.version) catch {};
        return .failed_install;
    };
    deps.linker.linkOpt(keg_name, receipt.version) catch |e| {
        output.warn("opt link for {s} failed: {s} — dependents may fail to load at runtime", .{ keg_name, @errorName(e) });
    };
    recordDepsFromList(deps.db, keg_id, receipt.runtime_deps);

    // Tap kegs aren't reachable from the bottle DSL pipeline (its body
    // locator only knows homebrew-core), so a `def post_install` in the
    // tap's .rb is resolved here and either deferred onto the queue
    // (parallel path, drained after every keg's `linkOpt`) or driven
    // inline. Outcome routing matches the install path byte-for-byte:
    // "completed" / "partially skipped — use --use-system-ruby" / fatal.
    runTapPostInstallIfDefined(
        ctx,
        allocator,
        deps,
        keg_name,
        receipt.tap,
        receipt.version,
        receipt.source_path,
    );

    if (!has_bar) output.success("  {s} {s} migrated (from {s} tap)", .{ keg_name, receipt.version, receipt.tap });
    return .migrated;
}

/// Resolve the tap's post_install body and either queue it (so it
/// runs after every keg's `opt/<name>/` symlink is in place) or drive
/// it inline on the legacy single-keg path. Silent when the formula
/// has no hook at all; a declarative `post_install_steps` block has no
/// extractable body, so it warns instead of silently dropping the hook.
fn runTapPostInstallIfDefined(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    deps: MigrateDeps,
    name: []const u8,
    tap: []const u8,
    version_str: []const u8,
    receipt_source_path: []const u8,
) void {
    const rb_path = findTapFormulaRb(ctx.io, allocator, deps.homebrew_prefix, tap, name, receipt_source_path) orelse return;
    defer allocator.free(rb_path);
    const body = post_install_mod.extractRbPostInstallBody(ctx.io, allocator, rb_path) orelse {
        if (post_install_mod.rbHasPostInstallSteps(ctx.io, allocator, rb_path))
            output.warn("    {s}: post_install skipped (declarative steps need formula JSON, unavailable for tap kegs; run brew postinstall {s})", .{ name, name });
        return;
    };
    defer allocator.free(body);

    if (deps.post_install_queue) |q| {
        q.addTap(ctx.io, name, version_str, body) catch |e| {
            output.warn("    {s}: failed to queue post_install ({s}); running inline", .{ name, @errorName(e) });
            post_install_mod.driveTap(
                ctx,
                allocator,
                name,
                version_str,
                body,
                deps.prefix,
                deps.use_system_ruby_scope,
                install_sink_mod.terminal,
            );
        };
    } else {
        post_install_mod.driveTap(
            ctx,
            allocator,
            name,
            version_str,
            body,
            deps.prefix,
            deps.use_system_ruby_scope,
            install_sink_mod.terminal,
        );
    }
}

/// Resolve the `<name>.rb` source for a tap keg. Prefers the receipt's
/// `source.path` (modern brew populates it for tap formulae), falling
/// back to the canonical `Library/Taps/<user>/homebrew-<repo>/Formula/`
/// layout — sharded first, then flat — so older receipts still hit a
/// real file. Returns a caller-owned absolute path or null.
pub fn findTapFormulaRb(
    io: std.Io,
    allocator: std.mem.Allocator,
    homebrew_prefix: []const u8,
    tap: []const u8,
    name: []const u8,
    receipt_source_path: []const u8,
) ?[]const u8 {
    if (receipt_source_path.len > 0 and std.mem.endsWith(u8, receipt_source_path, ".rb")) {
        if (std.Io.Dir.accessAbsolute(io, receipt_source_path, .{})) |_| {
            return allocator.dupe(u8, receipt_source_path) catch null;
        } else |_| {
            // Receipt path stale (tap moved/uninstalled) — fall through.
        }
    }

    const slash = std.mem.indexOfScalar(u8, tap, '/') orelse return null;
    const user = tap[0..slash];
    const raw_repo = tap[slash + 1 ..];
    if (user.len == 0 or raw_repo.len == 0) return null;
    const repo = if (std.mem.startsWith(u8, raw_repo, "homebrew-"))
        raw_repo["homebrew-".len..]
    else
        raw_repo;
    if (repo.len == 0) return null;

    var tap_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tap_path = std.fmt.bufPrint(&tap_buf, "{s}/Library/Taps/{s}/homebrew-{s}", .{
        homebrew_prefix, user, repo,
    }) catch return null;

    var rb_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sharded = std.fmt.bufPrint(&rb_buf, "{s}/Formula/{c}/{s}.rb", .{
        tap_path, name[0], name,
    }) catch return null;
    if (std.Io.Dir.accessAbsolute(io, sharded, .{})) |_| {
        return allocator.dupe(u8, sharded) catch null;
    } else |_| {}

    const flat = std.fmt.bufPrint(&rb_buf, "{s}/Formula/{s}.rb", .{ tap_path, name }) catch return null;
    if (std.Io.Dir.accessAbsolute(io, flat, .{})) |_| {
        return allocator.dupe(u8, flat) catch null;
    } else |_| {}

    return null;
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
    return readFileToOwnedSlice(io, allocator, file, @intCast(stat.size));
}

/// `realloc` keeps the returned slice's length in sync with its
/// allocation when `expected_size` over-estimates — covers the
/// stat-vs-read race so the result is safe to free under any allocator.
fn readFileToOwnedSlice(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    expected_size: usize,
) ![]u8 {
    const buf = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return allocator.realloc(buf, n);
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
    bar: ?*progress_mod.ProgressBar,
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

    if (bar == null) output.info("    Downloading {s}...", .{name});

    const progress_cb: ?client_mod.ProgressCallback = if (bar) |b| .{
        .context = @ptrCast(b),
        .func = &migrateBarBridge,
    } else null;

    _ = bottle_mod.download(ctx.io, allocator, ghcr, http, repo, digest, sha256, tmp_dir, progress_cb, null) catch {
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

/// Release `db_mu` before the OOM-fallback Ruby subprocess so other
/// parallel workers don't stall on it for the duration of the spawn.
/// `drive()` is read-only against the keg row, so no reacquire is
/// needed — caller suppresses the deferred unlock via the returned bool.
fn releaseDbMuForOomFallback(io: std.Io, db_mu: ?*std.Io.Mutex) bool {
    if (db_mu) |m| {
        m.unlock(io);
        return true;
    }
    return false;
}

/// Bump the store refcount under `db_mu`. `incrementRef`'s autocommit
/// `INSERT INTO store_refs` shares the migrate connection with every
/// worker's keg transaction; guarded only by its own `store.mutex` it
/// can land between a peer worker's `INSERT INTO kegs` and that
/// worker's connection-global `last_insert_rowid()` read, handing the
/// peer a foreign rowid. Taking `db_mu` makes it the single
/// connection-wide write lock so no insert escapes it. Serial callers
/// pass `db_mu == null` and pay no lock cost.
fn incrementRefLocked(
    io: std.Io,
    store: *store_mod.Store,
    db_mu: ?*std.Io.Mutex,
    sha256: []const u8,
    keg_name: []const u8,
) void {
    if (db_mu) |m| m.lockUncancelable(io);
    defer if (db_mu) |m| m.unlock(io);
    store.incrementRef(sha256) catch |e| {
        std.log.warn("refcount increment failed for {s}: {s}", .{ keg_name, @errorName(e) });
    };
}

// ── DB helpers (same pattern as install.zig) ────────────────────────

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

pub fn isInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}

// ─── inline test scratch ──────────────────────────────────────────────

const dbg_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(dbg_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

test "findTapFormulaRb prefers the receipt's source.path when it exists and ends in .rb" {
    var s = try Scratch.init("taprb_src");
    defer s.deinit();
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, s.base, .default_dir);

    const rb = s.p("/glow.rb");
    const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, rb, .{ .truncate = true });
    f.close(std.Options.debug_io);

    const got = findTapFormulaRb(
        std.Options.debug_io,
        std.testing.allocator,
        "/nonexistent/brew",
        "charmbracelet/tap",
        "glow",
        rb,
    );
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualStrings(rb, got.?);
}

test "findTapFormulaRb falls back to the canonical sharded tap layout when source.path is stale" {
    var s = try Scratch.init("taprb_sharded");
    defer s.deinit();
    const dir = s.base;

    const formula_dir = s.p("/Library/Taps/charmbracelet/homebrew-tap/Formula/g");
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, formula_dir);
    const rb = s.p("/Library/Taps/charmbracelet/homebrew-tap/Formula/g/glow.rb");
    (try std.Io.Dir.createFileAbsolute(std.Options.debug_io, rb, .{ .truncate = true }))
        .close(std.Options.debug_io);

    const got = findTapFormulaRb(
        std.Options.debug_io,
        std.testing.allocator,
        dir,
        "charmbracelet/tap",
        "glow",
        "/missing/path.rb",
    );
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expect(std.mem.endsWith(u8, got.?, "/Formula/g/glow.rb"));
}

test "findTapFormulaRb falls back to the flat tap layout when sharded is absent" {
    var s = try Scratch.init("taprb_flat");
    defer s.deinit();
    const dir = s.base;

    const formula_dir = s.p("/Library/Taps/user/homebrew-private/Formula");
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, formula_dir);
    const rb = s.p("/Library/Taps/user/homebrew-private/Formula/widget.rb");
    (try std.Io.Dir.createFileAbsolute(std.Options.debug_io, rb, .{ .truncate = true }))
        .close(std.Options.debug_io);

    const got = findTapFormulaRb(
        std.Options.debug_io,
        std.testing.allocator,
        dir,
        "user/private",
        "widget",
        "",
    );
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expect(std.mem.endsWith(u8, got.?, "/Formula/widget.rb"));
}

test "findTapFormulaRb does not double-prefix when the tap repo already starts with homebrew-" {
    var s = try Scratch.init("taprb_no_double");
    defer s.deinit();
    const dir = s.base;

    const formula_dir = s.p("/Library/Taps/user/homebrew-foo/Formula/w");
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, formula_dir);
    const rb = s.p("/Library/Taps/user/homebrew-foo/Formula/w/widget.rb");
    (try std.Io.Dir.createFileAbsolute(std.Options.debug_io, rb, .{ .truncate = true }))
        .close(std.Options.debug_io);

    const got = findTapFormulaRb(
        std.Options.debug_io,
        std.testing.allocator,
        dir,
        "user/homebrew-foo",
        "widget",
        "",
    );
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expect(std.mem.indexOf(u8, got.?, "/homebrew-foo/") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.?, "/homebrew-homebrew-") == null);
}

test "findTapFormulaRb returns null when neither the receipt path nor the canonical layout exists" {
    var s = try Scratch.init("taprb_none");
    defer s.deinit();
    const dir = s.base;
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, dir, .default_dir);

    try std.testing.expect(findTapFormulaRb(
        std.Options.debug_io,
        std.testing.allocator,
        dir,
        "charmbracelet/tap",
        "glow",
        "",
    ) == null);
}

test "findTapFormulaRb refuses a malformed tap (missing slash) instead of guessing a path" {
    // The scratch base is deliberately never created: the tap is rejected
    // before any path is touched.
    var s = try Scratch.init("taprb_bad");
    defer s.deinit();
    try std.testing.expect(findTapFormulaRb(
        std.Options.debug_io,
        std.testing.allocator,
        s.base,
        "noslash",
        "glow",
        "",
    ) == null);
}

test "readFileToOwnedSlice trims allocation when expected_size exceeds bytes read" {
    var s = try Scratch.init("receipt_short_read");
    defer s.deinit();
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, s.base, .default_dir);

    const path = s.p("/short.json");
    {
        const w = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        defer w.close(std.Options.debug_io);
        try w.writeStreamingAll(std.Options.debug_io, "hello");
    }

    const r = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{});
    defer r.close(std.Options.debug_io);

    // Overshoot is the stat-vs-read shortfall — the result must still
    // be safe to free under DebugAllocator.
    const text = try readFileToOwnedSlice(std.Options.debug_io, std.testing.allocator, r, 100);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "readFileToOwnedSlice returns the full buffer when expected_size matches bytes read" {
    var s = try Scratch.init("receipt_exact_read");
    defer s.deinit();
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, s.base, .default_dir);

    const path = s.p("/exact.json");
    const payload = "{\"version\":1}";
    {
        const w = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        defer w.close(std.Options.debug_io);
        try w.writeStreamingAll(std.Options.debug_io, payload);
    }

    const r = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{});
    defer r.close(std.Options.debug_io);

    const text = try readFileToOwnedSlice(std.Options.debug_io, std.testing.allocator, r, payload.len);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(payload, text);
}

test "readInstallReceipt round-trips a real INSTALL_RECEIPT.json under DebugAllocator" {
    var s = try Scratch.init("install_receipt_roundtrip");
    defer s.deinit();
    const dir = s.base;
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, dir, .default_dir);

    const payload = "{\"source\":{\"versions\":{\"stable\":\"1.0\"}},\"tap\":\"u/t\"}";
    const path = s.p("/INSTALL_RECEIPT.json");
    {
        const w = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        defer w.close(std.Options.debug_io);
        try w.writeStreamingAll(std.Options.debug_io, payload);
    }

    const text = try readInstallReceipt(std.Options.debug_io, std.testing.allocator, dir);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(payload, text);
}

test "full_name buffer fits realistic long tap+keg combinations" {
    // Long org/tap pairs in private taps plus long formula names push
    // the qualified `<tap>/<keg_name>` past 256 bytes; the qualifier
    // must still land in the DB row, otherwise `mt info <tap>/<name>`
    // and uninstall-by-full-name silently miss it.
    const tap = "someorg-with-an-unusually-long-organisation-name/private-platform-libs-very-deeply-namespaced-and-extra-padded-tap-name";
    const keg_name = "very-long-formula-name-that-stretches-the-qualified-path-comfortably-beyond-the-old-256-byte-buffer-with-padding-for-the-slash-separator-and-then-still-more-padding-yet-more";
    const need = tap.len + 1 + keg_name.len;
    comptime std.debug.assert(need > 256);

    try std.testing.expect(need <= full_name_buf_len);

    var buf: [full_name_buf_len]u8 = undefined;
    const got = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ tap, keg_name });
    try std.testing.expect(std.mem.startsWith(u8, got, tap));
    try std.testing.expect(std.mem.endsWith(u8, got, keg_name));
    try std.testing.expect(got[tap.len] == '/');
}

test "releaseDbMuForOomFallback hands db_mu back so peers don't stall on the inline subprocess" {
    // Worker holds db_mu, q.add OOMs, fallback runs inline drive(): the
    // mutex must be observably released before drive starts so other
    // parallel workers can make progress. tryLock from the same thread
    // succeeds iff the mutex is currently free (cmpxchg on the atomic
    // state, no thread-ownership tracking).
    var m: std.Io.Mutex = .init;
    m.lockUncancelable(std.Options.debug_io);

    try std.testing.expect(releaseDbMuForOomFallback(std.Options.debug_io, &m));
    try std.testing.expect(m.tryLock());
    m.unlock(std.Options.debug_io);
}

test "releaseDbMuForOomFallback is a no-op on the serial path (db_mu null)" {
    try std.testing.expect(!releaseDbMuForOomFallback(std.Options.debug_io, null));
}

// Reproduces the migrate --parallel shared-connection race: peer workers
// hammer `incrementRef` while one worker records kegs. Because
// `last_insert_rowid()` is connection-global, an unguarded refcount
// insert landing between a worker's `INSERT INTO kegs` and its rowid read
// hands the worker a foreign keg_id. The fix routes the bump through
// `incrementRefLocked` so it serialises on `db_mu`; with that lock no
// connection write escapes and every keg_id resolves to its own row.
test "incrementRef under db_mu keeps each worker's keg_id bound to its own kegs row" {
    const schema = @import("../../db/schema.zig");

    // Sharing one connection across threads is only sound in SQLite's
    // serialized mode — the same contract migrate --parallel enforces.
    if (sqlite.threadsafeMode() != 1) return error.SkipZigTest;

    const io = std.Options.debug_io;
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var store = store_mod.Store.init(io, std.testing.allocator, &db, "");
    var db_mu: std.Io.Mutex = .init;

    const Ctx = struct {
        io: std.Io,
        db: *sqlite.Database,
        store: *store_mod.Store,
        db_mu: *std.Io.Mutex,
        keg_seq: std.atomic.Value(u64) = .init(0),
        ref_seq: std.atomic.Value(u64) = .init(0),
        done: std.atomic.Value(bool) = .init(false),
        leaked: std.atomic.Value(bool) = .init(false),

        fn nameMatches(d: *sqlite.Database, keg_id: i64, name: []const u8) bool {
            var stmt = d.prepare("SELECT name FROM kegs WHERE id = ?1;") catch return false;
            defer stmt.finalize();
            stmt.bindInt(1, keg_id) catch return false;
            if (!(stmt.step() catch false)) return false; // id points at no keg row
            const got = stmt.columnText(0) orelse return false;
            return std.mem.eql(u8, std.mem.sliceTo(got, 0), name);
        }

        fn recordLoop(c: *@This(), iters: usize) void {
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const n = c.keg_seq.fetchAdd(1, .monotonic);
                var name_buf: [32]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "keg-{d}", .{n}) catch unreachable;
                c.db_mu.lockUncancelable(c.io);
                if (record.recordKegFields(c.db, .{
                    .name = name,
                    .full_name = name,
                    .version = "1",
                    .revision = 0,
                    .tap = "",
                    .store_sha256 = "",
                    .cellar_path = "",
                    .install_reason = "direct",
                    .bin_isolated = false,
                }, .{})) |keg_id| {
                    recordDepsFromList(c.db, keg_id, &.{"libdep"});
                    if (!nameMatches(c.db, keg_id, name)) c.leaked.store(true, .monotonic);
                } else |_| {}
                c.db_mu.unlock(c.io);
            }
            c.done.store(true, .release);
        }

        fn hammer(c: *@This()) void {
            // Spin until the recorder is done so the overlap covers the
            // whole record loop. Each sha is unique so the bump is a fresh
            // INSERT (an ON CONFLICT UPDATE leaves last_insert_rowid alone
            // and would hide the race). Capped so a missed `done` can't run
            // the table away with memory.
            var i: usize = 0;
            while (i < 2_000_000 and !c.done.load(.acquire)) : (i += 1) {
                const n = c.ref_seq.fetchAdd(1, .monotonic);
                var sha_buf: [32]u8 = undefined;
                const sha = std.fmt.bufPrint(&sha_buf, "ref-{d}", .{n}) catch unreachable;
                incrementRefLocked(c.io, c.store, c.db_mu, sha, "race");
            }
        }
    };

    var ctx = Ctx{ .io = io, .db = &db, .store = &store, .db_mu = &db_mu };

    const h1 = try std.Thread.spawn(.{}, Ctx.hammer, .{&ctx});
    const h2 = try std.Thread.spawn(.{}, Ctx.hammer, .{&ctx});
    Ctx.recordLoop(&ctx, 4000);
    h1.join();
    h2.join();

    try std.testing.expect(!ctx.leaked.load(.monotonic));
}

test "incrementRefLocked on the serial path (db_mu null) still bumps the refcount" {
    const schema = @import("../../db/schema.zig");
    const io = std.Options.debug_io;
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var store = store_mod.Store.init(io, std.testing.allocator, &db, "");
    // Serial callers pass db_mu == null: no lock, no deadlock, ref still lands.
    incrementRefLocked(io, &store, null, "deadbeef", "solo");

    var stmt = try db.prepare("SELECT refcount FROM store_refs WHERE store_sha256 = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, "deadbeef");
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
}

test "migrate keg record through the shared seam preserves pin inheritance, bin_isolated=0, and own-txn commit" {
    const schema = @import("../../db/schema.zig");
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const fields = record.KegFields{
        .name = "wget",
        .full_name = "wget",
        .version = "1.21",
        .revision = 0,
        .tap = "",
        .store_sha256 = "",
        .cellar_path = "/opt/malt/Cellar/wget/1.21",
        .install_reason = "direct",
        // migrate has no bin-isolation intent — byte-identical to the old omit→default.
        .bin_isolated = false,
    };

    // First migrate-style record, then a user pin, then a re-migrate of the
    // same name: COALESCE-MAX must carry the pin across INSERT OR REPLACE.
    const id1 = try record.recordKegFields(&db, fields, .{});
    {
        var s = try db.prepare("UPDATE kegs SET pinned = 1 WHERE id = ?1;");
        defer s.finalize();
        try s.bindInt(1, id1);
        _ = try s.step();
    }
    _ = try record.recordKegFields(&db, fields, .{});

    // Fresh statement reads the committed row: pin inherited, bin_isolated 0.
    var q = try db.prepare("SELECT pinned, bin_isolated FROM kegs WHERE name = ?1;");
    defer q.finalize();
    try q.bindText(1, "wget");
    try std.testing.expect(try q.step());
    try std.testing.expectEqual(@as(i64, 1), q.columnInt(0));
    try std.testing.expectEqual(@as(i64, 0), q.columnInt(1));
}
