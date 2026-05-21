//! malt — outdated refresh pipeline
//!
//! Live-audit machinery for `mt outdated` and `mt update --check`:
//! a bounded thread pool fetches the upstream latest for each
//! installed keg, the orchestrator stitches the diff together, and
//! `refreshSnapshot` writes the cached `outdated.json` so subsequent
//! invocations stay instant.

const std = @import("std");

const AppCtx = @import("../../app_ctx.zig").AppCtx;
const cask_mod = @import("../../core/cask.zig");
const tap_mod = @import("../../core/tap.zig");
const sqlite = @import("../../db/sqlite.zig");
const api_mod = @import("../../net/api.zig");
const client_mod = @import("../../net/client.zig");
const output = @import("../../ui/output.zig");
const install_args_mod = @import("../install/args.zig");
const install_rb_parse_mod = @import("../install/rb_parse.zig");
const rows_mod = @import("rows.zig");
const KegRow = rows_mod.KegRow;
const snap_mod = @import("snapshot.zig");
const OutdatedEntry = snap_mod.OutdatedEntry;

/// Default ceiling on concurrent API fetches. One round-trip per keg
/// dominates `mt outdated` on machines with many installed packages, so
/// we hand the work to a bounded pool the same way `cli/install` and
/// `cli/search` do.
pub const OUTDATED_DEFAULT_WORKERS: usize = 8;

/// Env var that lets users tune the pool size (e.g. crank it on a fat
/// uplink, or lower it to one to reproduce serial behaviour).
pub const OUTDATED_WORKERS_ENV = "MALT_OUTDATED_WORKERS";

/// Parse the worker-count override env var. Anything non-positive or
/// non-numeric falls back to the default — matches the lenient style
/// the rest of the CLI uses for tuning knobs.
pub fn parseWorkersEnv(s: ?[]const u8) ?usize {
    const raw = s orelse return null;
    if (raw.len == 0) return null;
    const n = std.fmt.parseInt(usize, raw, 10) catch return null;
    if (n == 0) return null;
    return n;
}

/// Resolve the actual worker count for `jobs`. Capped at `jobs` so we
/// never spawn idle workers, and at the env override (or the default
/// ceiling) so we never starve the network.
pub fn outdatedWorkerCount(jobs: usize, env_override: ?usize) usize {
    const cap = env_override orelse OUTDATED_DEFAULT_WORKERS;
    return @min(cap, jobs);
}

/// Below this we keep the single-client serial path — the pool's
/// thread-spawn + HTTP-pool init overhead is not worth it for a
/// handful of round-trips.
pub fn shouldUsePool(jobs: usize) bool {
    return jobs >= OUTDATED_DEFAULT_WORKERS;
}

/// Recompute every outdated entry (formulas + casks) and overwrite the
/// snapshot at `{cache_dir}/outdated.json`. Best-effort: failures are
/// folded into the caller's `catch {}` so a snapshot write never blocks
/// the user-facing output that already succeeded.
pub fn refreshSnapshot(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    workers_override: ?usize,
) !void {
    const formula_rows = try rows_mod.loadFormulaRows(allocator, db, .all);
    defer rows_mod.freeKegRows(allocator, formula_rows);
    const cask_rows = try rows_mod.loadCaskRows(allocator, db, .all);
    defer rows_mod.freeKegRows(allocator, cask_rows);

    const formulas = try collectOutdatedFormulas(ctx, allocator, api, cache_dir, formula_rows, workers_override);
    defer {
        for (formulas) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        allocator.free(formulas);
    }
    const casks = try collectOutdatedCasks(ctx, allocator, api, cache_dir, cask_rows, workers_override);
    defer {
        for (casks) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        allocator.free(casks);
    }

    try snap_mod.writeSnapshot(ctx.io, allocator, cache_dir, .{
        .generated_at_ms = std.Io.Clock.real.now(ctx.io).toMilliseconds(),
        .formulas = formulas,
        .casks = casks,
    });
}

/// Compute outdated formulas for `kegs`. Sort order follows `kegs` —
/// callers query the DB with `ORDER BY name`. Per-row API failures or
/// 404s drop silently (matches the old serial behaviour).
pub fn collectOutdatedFormulas(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
) std.mem.Allocator.Error![]OutdatedEntry {
    return collectOutdated(ctx, allocator, api, cache_dir, kegs, workers_override, .formula);
}

/// Cask sibling of `collectOutdatedFormulas`. Same lifetime contract.
pub fn collectOutdatedCasks(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
) std.mem.Allocator.Error![]OutdatedEntry {
    return collectOutdated(ctx, allocator, api, cache_dir, kegs, workers_override, .cask);
}

const Kind = enum { formula, cask };

fn collectOutdated(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
    kind: Kind,
) std.mem.Allocator.Error![]OutdatedEntry {
    if (kegs.len == 0) return allocator.alloc(OutdatedEntry, 0);

    // Per-row latest-version slot. Workers fill `latest_versions[i]`
    // with a caller-allocator-owned string when row `i` is outdated;
    // null otherwise. Indexed-write keeps the pool free of locks.
    const latest_versions = try allocator.alloc(?[]u8, kegs.len);
    defer allocator.free(latest_versions);
    @memset(latest_versions, null);
    errdefer for (latest_versions) |maybe| {
        if (maybe) |v| allocator.free(v);
    };

    if (!shouldUsePool(kegs.len)) {
        for (kegs, 0..) |row, i| {
            latest_versions[i] = try fetchLatest(allocator, api, ctx.io, ctx.environ, kind, row);
        }
    } else {
        try runPool(ctx, allocator, cache_dir, kegs, workers_override, kind, latest_versions);
    }

    return assembleEntries(allocator, kegs, latest_versions);
}

fn assembleEntries(
    allocator: std.mem.Allocator,
    kegs: []const KegRow,
    latest_versions: []?[]u8,
) std.mem.Allocator.Error![]OutdatedEntry {
    var out: std.ArrayList(OutdatedEntry) = try .initCapacity(allocator, kegs.len);
    errdefer {
        for (out.items) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        out.deinit(allocator);
    }

    for (kegs, 0..) |row, i| {
        const latest = latest_versions[i] orelse continue;
        // Hand ownership of `latest` over to the entry; clear the
        // slot so the errdefer above doesn't double-free it.
        latest_versions[i] = null;
        errdefer allocator.free(latest);

        const name_dup = try allocator.dupe(u8, row.name);
        errdefer allocator.free(name_dup);
        const installed_dup = try allocator.dupe(u8, row.version);

        try out.append(allocator, .{
            .name = name_dup,
            .installed = installed_dup,
            .latest = latest,
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Fetch + parse the upstream latest version for `row` onto `alloc`.
/// Best-effort: network or parse failures collapse to null. Shared by
/// the serial and pool paths so the JSON-shape logic lives once.
/// `io` and `environ` are only consumed by the tap-cask branch (which
/// needs them for the per-tap HEAD resolve + raw `.rb` fetch); core-
/// API formula/cask lookups go through `api` which already wraps the
/// shared HTTP client.
fn upstreamLatest(
    alloc: std.mem.Allocator,
    api: *api_mod.BrewApi,
    io: std.Io,
    environ: std.process.Environ,
    kind: Kind,
    row: KegRow,
) ?[]u8 {
    return switch (kind) {
        .formula => blk: {
            const json = api.fetchFormula(row.name) catch break :blk null;
            defer alloc.free(json);
            break :blk parseFormulaLatest(alloc, json);
        },
        .cask => blk: {
            // Pre-route to the owning tap when set: the core API 404s
            // for third-party-tap casks, so the API path would silently
            // drop the row from the audit. Same shape as `upgradeCask`.
            if (row.tap) |tap_label| {
                if (!install_args_mod.isCoreTap(tap_label)) {
                    break :blk tapCaskLatestVersion(alloc, io, environ, tap_label, row.name);
                }
            }
            const json = api.fetchCask(row.name) catch break :blk null;
            defer alloc.free(json);
            var cask = cask_mod.parseCask(alloc, json) catch break :blk null;
            defer cask.deinit();
            break :blk alloc.dupe(u8, cask.version) catch null;
        },
    };
}

/// Surface a tap HEAD-resolve failure during the outdated audit. Pre-
/// fix this collapsed silently to null and the cask got classified as
/// up-to-date — a real upgrade could sit unannounced for hours when
/// the only thing wrong was a transient rate limit. The wording mirrors
/// `describeResolveError` so the install/upgrade/outdated paths share
/// one user-actionable line.
fn warnTapHeadResolveFailed(tap_label: []const u8, err: tap_mod.TapError) void {
    output.warn(
        "Could not resolve {s}'s HEAD: {s}",
        .{ tap_label, tap_mod.describeResolveError(err) },
    );
}

/// Companion to `warnTapHeadResolveFailed` for the raw `.rb` fetch /
/// parse leg. Same intent — never silently drop a cask from the audit.
fn warnTapCaskFetchFailed(tap_label: []const u8, token: []const u8, reason: []const u8) void {
    output.warn(
        "Could not check {s}/{s} for upgrades: {s}",
        .{ tap_label, token, reason },
    );
}

/// Resolve a tap cask's upstream version by fetching the owning tap's
/// `Casks/<token>.rb` at fresh HEAD and reading the `version` field.
/// Returns null on any failure so the caller leaves the row alone, but
/// emits a one-line warning describing what went wrong — users (and
/// the regression-script skip-guards) can tell "really up to date" from
/// "couldn't reach the tap".
fn tapCaskLatestVersion(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    tap_label: []const u8,
    token: []const u8,
) ?[]u8 {
    const slash = std.mem.indexOfScalar(u8, tap_label, '/') orelse return null;
    if (slash == 0 or slash == tap_label.len - 1) return null;

    const urls = tap_mod.resolveTapBaseUrls(alloc, tap_label) catch return null;
    defer urls.deinit(alloc);

    const fresh_sha = tap_mod.resolveHeadCommit(io, environ, alloc, urls.api_head_url) catch |err| {
        warnTapHeadResolveFailed(tap_label, err);
        return null;
    };
    defer alloc.free(fresh_sha);

    var http = client_mod.HttpClient.init(io, environ, alloc);
    defer http.deinit();

    var rb_url_buf: [512]u8 = undefined;
    const rb_url = std.fmt.bufPrint(&rb_url_buf, "{s}/{s}/Casks/{s}.rb", .{ urls.raw_base, fresh_sha, token }) catch return null;

    var rb_resp = http.get(rb_url) catch {
        warnTapCaskFetchFailed(tap_label, token, "Network failure while reading the .rb");
        return null;
    };
    defer rb_resp.deinit();
    if (rb_resp.status != 200) {
        var status_buf: [64]u8 = undefined;
        const reason = std.fmt.bufPrint(&status_buf, "GitHub returned status {d} for the .rb", .{rb_resp.status}) catch "GitHub returned a non-200 status for the .rb";
        warnTapCaskFetchFailed(tap_label, token, reason);
        return null;
    }

    const rb_info = install_rb_parse_mod.parseRubyFormula(rb_resp.body) orelse {
        warnTapCaskFetchFailed(tap_label, token, "unsupported Ruby DSL shape — use `brew upgrade` for this cask");
        return null;
    };
    return alloc.dupe(u8, rb_info.version) catch null;
}

/// Serial-path single-row check. Returns a caller-owned latest-version
/// string if `row` is outdated, null otherwise.
fn fetchLatest(
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    io: std.Io,
    environ: std.process.Environ,
    kind: Kind,
    row: KegRow,
) std.mem.Allocator.Error!?[]u8 {
    const v = upstreamLatest(allocator, api, io, environ, kind, row) orelse return null;
    if (std.mem.eql(u8, row.version, v)) {
        allocator.free(v);
        return null;
    }
    return v;
}

/// Pull `versions.stable` out of a Homebrew formula JSON document.
/// Returns a fresh caller-owned copy or null if the field is missing /
/// the document is malformed.
fn parseFormulaLatest(allocator: std.mem.Allocator, json_bytes: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const versions_val = obj.get("versions") orelse return null;
    const versions_obj = switch (versions_val) {
        .object => |o| o,
        else => return null,
    };
    const stable_val = versions_obj.get("stable") orelse return null;
    return switch (stable_val) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    };
}

// --- Pool path ---

const WorkerCtx = struct {
    io: std.Io,
    /// Carried so tap-cask rows can resolve their owning tap's HEAD
    /// through `tap_mod.resolveHeadCommit`, which reads GitHub auth
    /// tokens from the parent process environ.
    environ: std.process.Environ,
    arena: std.heap.ArenaAllocator,
    pool: *client_mod.HttpClientPool,
    cache_dir: []const u8,
    row: KegRow,
    kind: Kind,
    /// Result allocated on the **caller** allocator so it survives
    /// arena teardown. Null = up-to-date or fetch failed.
    out: ?[]u8 = null,
    /// Out-of-memory from caller-allocator dupe; surfaced after join.
    /// Other failures stay silent to match the serial behaviour.
    err: ?std.mem.Allocator.Error = null,
};

const PoolState = struct {
    next_idx: std.atomic.Value(usize),
    ctxs: []WorkerCtx,
    out_allocator: std.mem.Allocator,
};

fn poolWorker(state: *PoolState) void {
    while (true) {
        const idx = state.next_idx.fetchAdd(1, .acq_rel);
        if (idx >= state.ctxs.len) return;
        const wctx = &state.ctxs[idx];
        runOne(state.out_allocator, wctx);
    }
}

fn runOne(out_alloc: std.mem.Allocator, wctx: *WorkerCtx) void {
    const http = wctx.pool.acquire();
    defer wctx.pool.release(http);

    const arena_alloc = wctx.arena.allocator();
    var local_api = api_mod.BrewApi.init(wctx.io, arena_alloc, http, wctx.cache_dir);
    const latest = upstreamLatest(arena_alloc, &local_api, wctx.io, wctx.environ, wctx.kind, wctx.row) orelse return;
    if (std.mem.eql(u8, wctx.row.version, latest)) return;

    // Move into the caller's allocator so the result outlives `arena.deinit()`.
    wctx.out = out_alloc.dupe(u8, latest) catch |e| blk: {
        wctx.err = e;
        break :blk null;
    };
}

fn runPool(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
    kind: Kind,
    latest_versions: []?[]u8,
) std.mem.Allocator.Error!void {
    const worker_count = outdatedWorkerCount(kegs.len, workers_override);
    std.debug.assert(worker_count > 0);

    var http_pool = try client_mod.HttpClientPool.init(ctx.io, ctx.environ, allocator, worker_count);
    defer http_pool.deinit();

    const ctxs = try allocator.alloc(WorkerCtx, kegs.len);
    defer {
        for (ctxs) |*c| c.arena.deinit();
        allocator.free(ctxs);
    }
    // Thread-safe heap for per-row worker arenas.
    for (ctxs, 0..) |*c, i| c.* = .{
        .io = ctx.io,
        .environ = ctx.environ,
        .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator),
        .pool = &http_pool,
        .cache_dir = cache_dir,
        .row = kegs[i],
        .kind = kind,
    };

    var state: PoolState = .{
        .next_idx = std.atomic.Value(usize).init(0),
        .ctxs = ctxs,
        .out_allocator = allocator,
    };

    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var spawned: usize = 0;
    for (0..worker_count) |_| {
        if (std.Thread.spawn(.{}, poolWorker, .{&state})) |t| {
            threads[spawned] = t;
            spawned += 1;
        } else |_| {
            // Spawn failure: drain remaining work inline on this thread.
            poolWorker(&state);
        }
    }
    for (threads[0..spawned]) |t| t.join();

    // Move every successful out into the caller's slot first so the
    // caller's errdefer can free partial-success memory if we then
    // surface a worker OOM.
    for (ctxs, 0..) |c, i| {
        latest_versions[i] = c.out;
    }
    for (ctxs) |c| {
        if (c.err) |e| return e;
    }
}

test "WorkerCtx: per-row arena accepts testing.allocator backing without leaking" {
    // Pin the per-row dupe + KB-scale alloc + deinit shape. Production
    // backs the same arena with `smp_allocator`; the inline test
    // guarantees `testing.allocator` still works so future leak coverage
    // can land here without re-plumbing.
    var wctx: WorkerCtx = .{
        .io = std.Options.debug_io,
        .environ = std.process.Environ.empty,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .pool = undefined,
        .cache_dir = "",
        .row = .{ .name = "", .version = "" },
        .kind = .formula,
    };
    defer wctx.arena.deinit();

    const a = wctx.arena.allocator();
    _ = try a.dupe(u8, "wget");
    _ = try a.alloc(u8, 1024);
}

test "outdatedWorkerCount caps at the default for large N" {
    try std.testing.expectEqual(
        @as(usize, OUTDATED_DEFAULT_WORKERS),
        outdatedWorkerCount(50, null),
    );
}

test "outdatedWorkerCount returns N when N is below the default" {
    try std.testing.expectEqual(@as(usize, 3), outdatedWorkerCount(3, null));
    try std.testing.expectEqual(@as(usize, 0), outdatedWorkerCount(0, null));
}

test "outdatedWorkerCount respects env overrides above and below the default" {
    try std.testing.expectEqual(@as(usize, 4), outdatedWorkerCount(50, 4));
    // Power-user override: env wins over the default ceiling.
    try std.testing.expectEqual(@as(usize, 16), outdatedWorkerCount(50, 16));
}

test "shouldUsePool flips at the default-worker boundary" {
    try std.testing.expect(!shouldUsePool(0));
    try std.testing.expect(!shouldUsePool(OUTDATED_DEFAULT_WORKERS - 1));
    try std.testing.expect(shouldUsePool(OUTDATED_DEFAULT_WORKERS));
    try std.testing.expect(shouldUsePool(50));
}

test "parseWorkersEnv parses a positive integer" {
    try std.testing.expectEqual(@as(?usize, 4), parseWorkersEnv("4"));
    try std.testing.expectEqual(@as(?usize, 16), parseWorkersEnv("16"));
}

test "parseWorkersEnv rejects null, empty, zero, and non-numeric values" {
    try std.testing.expectEqual(@as(?usize, null), parseWorkersEnv(null));
    try std.testing.expectEqual(@as(?usize, null), parseWorkersEnv(""));
    try std.testing.expectEqual(@as(?usize, null), parseWorkersEnv("0"));
    try std.testing.expectEqual(@as(?usize, null), parseWorkersEnv("abc"));
    try std.testing.expectEqual(@as(?usize, null), parseWorkersEnv("-3"));
}

test "warnTapHeadResolveFailed surfaces rate-limit reason with the tap label" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    warnTapHeadResolveFailed("yuzeguitarist/deck", tap_mod.TapError.RateLimited);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "yuzeguitarist/deck") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Could not resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "rate limit") != null);
}

test "warnTapHeadResolveFailed surfaces network failure for the regression skip-guards" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    warnTapHeadResolveFailed("user/repo", tap_mod.TapError.NetworkError);

    // Wording must hit both the user-facing "Could not resolve" header
    // and the existing skip-guard regex (`Network failure`) so the
    // regressions/*.sh scripts can tell a rate-limit fail from a real
    // assertion miss.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Could not resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Network failure") != null);
}

test "warnTapCaskFetchFailed names both the tap and the token" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    warnTapCaskFetchFailed("yuzeguitarist/deck", "deckclip", "GitHub returned status 404 for the .rb");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "yuzeguitarist/deck") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "deckclip") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "404") != null);
}

test "parseFormulaLatest pulls versions.stable from a real-shape document" {
    const json =
        \\{"name":"tree","versions":{"stable":"2.1.1","head":"HEAD","bottle":true},"oldname":null}
    ;
    const v = parseFormulaLatest(std.testing.allocator, json) orelse return error.UnexpectedNull;
    defer std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("2.1.1", v);
}

test "parseFormulaLatest returns null for every malformed or missing shape" {
    // One row per shape that should collapse to null. A real upstream
    // failure should land the keg as up-to-date rather than crash the
    // pool worker — `null` is the contract.
    const cases = [_][]const u8{
        "",
        "not-json",
        // Top-level not an object.
        "[]",
        "\"a string\"",
        // No `versions` field.
        "{}",
        // `versions` is not an object.
        "{\"versions\":[]}",
        "{\"versions\":\"1.0\"}",
        // `versions` lacks `stable`.
        "{\"versions\":{\"head\":\"HEAD\"}}",
        // `stable` is not a string.
        "{\"versions\":{\"stable\":42}}",
        "{\"versions\":{\"stable\":null}}",
        "{\"versions\":{\"stable\":[\"1.0\"]}}",
    };
    for (cases) |c| {
        const got = parseFormulaLatest(std.testing.allocator, c);
        if (got) |v| {
            std.testing.allocator.free(v);
            std.debug.print("expected null for input: {s}\n", .{c});
            return error.UnexpectedValue;
        }
    }
}
