//! malt — vulns command
//! Report open advisories for installed formulae: core kegs from the formula
//! API, tap kegs from OSV.dev keyed on their recipe's source url.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const formula_mod = @import("../core/formula.zig");
const signals = @import("../core/signals.zig");
const schema = @import("../db/schema.zig");
const schema_report = @import("schema_report.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const pool_mod = @import("../net/client_pool.zig");
const outdated = @import("outdated.zig");
const refresh = @import("outdated/refresh.zig");
const output = @import("../ui/output.zig");
const term_sanitize = @import("../ui/term_sanitize.zig");
const help = @import("help.zig");
const install_args = @import("install/args.zig");
const rb_parse = @import("install/rb_parse.zig");
const identify = @import("vulns/identify.zig");
const tap_mod = @import("../core/tap.zig");
const osv = @import("../net/osv.zig");

/// One checked package. `vulns` borrows from `formula` for a core entry and
/// from the arena for a tap entry.
const Entry = struct {
    name: []const u8,
    /// Null when the name was asked for on the command line but is not installed.
    installed_version: ?[]const u8,
    /// The API parse, kept alive for the rows; a tap entry has none.
    formula: ?formula_mod.Formula,
    vulns: []const formula_mod.Vuln,
};

/// Everything the writers need, so human and JSON output share one call.
const Report = struct {
    entries: []const Entry,
    rows: []const Row,
    /// Names whose metadata could not be fetched; the scan is incomplete.
    unchecked: []const []const u8,
    /// Kegs the implicit walk could not attribute to any advisory source.
    not_covered: usize,
};

/// Where the tap phase reads recipes and advisories from. Production uses
/// the defaults; tests point both at one loopback fixture, which is why the
/// OSV base is not a `Mirrors` knob (those are https-only and env-driven).
pub const Sources = struct {
    osv_base: []const u8 = osv.default_base_url,
    /// Replaces every tap's forge when set: raw recipes are read under it
    /// and its HEAD is `<forge_base>/commits/HEAD`.
    forge_base: ?[]const u8 = null,
};

/// Detail fetches are one GET per advisory; past this many the rest are
/// listed by id alone so a widely-affected Cellar does not turn into a sweep.
/// Only when nothing rides on the rank: a severity filter needs every row
/// ranked, or the unranked ones would slip out of the report.
const max_detail_fetches: usize = 20;

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return executeWith(ctx, allocator, args, .{});
}

pub fn executeWith(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8, sources: Sources) !void {
    if (help.showIfRequested(ctx, args, "vulns")) return;

    var min_severity: ?Severity = null;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        var value: ?[]const u8 = null;
        if (std.mem.eql(u8, arg, "--severity")) {
            if (i + 1 >= args.len) {
                output.err("--severity requires a level (low, medium, high, critical)", .{});
                return error.Aborted;
            }
            i += 1;
            value = args[i];
        } else if (std.mem.startsWith(u8, arg, "--severity=")) {
            value = arg["--severity=".len..];
        } else if (arg.len > 0 and arg[0] != '-') {
            // A repeated name would be fetched and listed twice.
            for (names.items) |seen| {
                if (std.mem.eql(u8, seen, arg)) break;
            } else try names.append(allocator, arg);
        }
        if (value) |v| {
            min_severity = parseSeverityFlag(v) orelse {
                output.err("unknown severity '{s}' (use low, medium, high, or critical)", .{v});
                return error.Aborted;
            };
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const installed = try readInstalled(ctx.io, arena);
    const walk_all = names.items.len == 0;
    // A named tap keg is asked of its tap, never of the API that cannot know it.
    var targets: std.ArrayList([]const u8) = .empty;
    var selected_taps: std.ArrayList(TapKeg) = .empty;
    if (walk_all) {
        try targets.appendSlice(arena, installed.core.keys());
        try selected_taps.appendSlice(arena, installed.tap_kegs.items);
    } else for (names.items) |name| {
        if (installed.tapKeg(name)) |keg| try selected_taps.append(arena, keg) else try targets.append(arena, name);
    }
    // Tap kegs need the network for their recipe; offline they simply stay
    // uncovered, the way the API tier degrades to its cache.
    const tap_kegs: []const TapKeg = if (ctx.offline) &.{} else selected_taps.items;

    const fetches = try allocator.alloc(Fetch, targets.items.len);
    defer {
        for (fetches) |f| if (f.body) |b| std.heap.smp_allocator.free(b);
        allocator.free(fetches);
    }
    for (fetches, targets.items) |*f, name| f.* = .{ .name = name };
    const cache_dir = try atomic.maltCacheDir(allocator);
    defer allocator.free(cache_dir);

    // One pool for both phases; the main thread borrows a client for OSV.
    const workers = @max(1, refresh.outdatedWorkerCount(@max(fetches.len, tap_kegs.len), null));
    var pool = try pool_mod.HttpClientPool.init(ctx.io, ctx.environ, allocator, workers);
    defer pool.deinit();
    pool.setOfflineAll(ctx.offline);
    var checking_buf: [128]u8 = undefined;
    if (checkingMessage(&checking_buf, fetches.len, tap_kegs.len)) |msg| output.info("{s}", .{msg});
    try fetchAll(ctx, allocator, cache_dir, &pool, fetches);
    // Cancelled fetches all fail alike; the interrupt is the real story.
    if (signals.isInterrupted()) return error.UserInterrupted;

    const tap_fetches = try allocator.alloc(TapFetch, tap_kegs.len);
    defer allocator.free(tap_fetches);
    for (tap_fetches, tap_kegs) |*f, keg| f.* = .{ .keg = keg };
    try resolveTapKegs(ctx, allocator, &pool, sources.forge_base, tap_fetches);
    if (signals.isInterrupted()) return error.UserInterrupted;

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*e| if (e.formula) |*f| f.deinit();
        entries.deinit(allocator);
    }
    var unchecked: std.ArrayList([]const u8) = .empty;
    defer unchecked.deinit(allocator);
    // One bad fetch must not cost the rest of the report: a formula Homebrew
    // renamed since it was installed is a routine 404. Warnings are emitted in
    // command-line order regardless of which worker hit them first.
    for (fetches) |fetch| {
        const name = fetch.name;
        const body = fetch.body orelse {
            switch (fetch.err.?) {
                api_mod.ApiError.NotFound => output.warnAlways("{s}: not a formula in the API", .{name}),
                api_mod.ApiError.InvalidName => output.warnAlways("{s}: not a valid formula name", .{name}),
                api_mod.ApiError.OfflineRequired => output.warnAlways("offline mode: formula '{s}' not cached", .{name}),
                else => |e| output.warnAlways("{s}: could not fetch formula metadata ({s})", .{ name, @errorName(e) }),
            }
            try unchecked.append(allocator, name);
            continue;
        };
        const f = formula_mod.parseFormula(allocator, body) catch {
            output.warnAlways("{s}: unreadable formula metadata", .{name});
            try unchecked.append(allocator, name);
            continue;
        };
        try entries.append(allocator, .{
            .name = name,
            .installed_version = installed.core.get(name),
            .formula = f,
            .vulns = f.vulns_open,
        });
    }

    // Coverage counts what was actually asked for: the --local kegs only
    // when everything was, tap kegs whenever they were selected.
    var not_covered: usize = if (walk_all) installed.skipped else 0;
    if (ctx.offline) not_covered += selected_taps.items.len;
    const detail_cap: usize = if (min_severity != null) std.math.maxInt(usize) else max_detail_fetches;
    not_covered += try scanTapKegs(allocator, arena, &pool, sources.osv_base, detail_cap, tap_fetches, &entries, &unchecked);
    if (signals.isInterrupted()) return error.UserInterrupted;

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    for (entries.items) |e| {
        for (e.vulns) |v| {
            if (keeps(min_severity, v)) try rows.append(allocator, .{ .name = e.name, .vuln = v });
        }
    }
    std.mem.sort(Row, rows.items, {}, rowLessThan);

    try report(ctx, .{
        .entries = entries.items,
        .rows = rows.items,
        .unchecked = unchecked.items,
        .not_covered = not_covered,
    });
    try exitStatus(rows.items.len, unchecked.items.len);
}

fn report(ctx: *const AppCtx, r: Report) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = ctx.stdout.writer(ctx.io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    // Flush before the exit-code error so the rows reach a pipe reader.
    defer stdout.flush() catch {};

    if (output.isJson()) return writeJson(stdout, r);

    try writeHuman(stdout, r.rows);
    var msg_buf: [256]u8 = undefined;
    for (r.entries) |e| {
        // A tap recipe is read at the installed commit; only the API's
        // current view can be ahead of a keg.
        const f = e.formula orelse continue;
        if (staleNotice(&msg_buf, e.name, f.pkg_version, e.installed_version, r.rows)) |msg|
            output.warnAlways("{s}", .{msg});
    }
    // Silence reads as "did it run?"; say what was checked, like `outdated`.
    if (r.rows.len == 0) output.info("{s}", .{allClearMessage(&msg_buf, r.entries.len, r.unchecked.len)});
    if (coverageMessage(&msg_buf, r.not_covered)) |msg| output.info("{s}", .{msg});
}

/// The API judges the tap's current version; an older keg may carry
/// advisories the list does not show, so say so once per affected formula.
fn staleNotice(buf: []u8, name: []const u8, upstream: []const u8, installed: ?[]const u8, rows: []const Row) ?[]const u8 {
    const inst = installed orelse return null;
    if (std.mem.eql(u8, inst, upstream)) return null;
    for (rows) |r| {
        if (std.mem.eql(u8, r.name, name)) break;
    } else return null;
    return std.fmt.bufPrint(buf, "{s}: open at {s}; installed {s} may carry more", .{ name, upstream, inst }) catch null;
}

/// One formula fetch; exactly one of `body` / `err` is set after `fetchAll`.
/// `body` lives on `std.heap.smp_allocator` because a worker thread wrote it.
const Fetch = struct {
    name: []const u8,
    body: ?[]const u8 = null,
    err: ?api_mod.ApiError = null,
};

/// Atomic take-next over `items`; every take borrows one pooled client.
fn WorkQueue(comptime Item: type, comptime Extra: type, comptime work: fn (Extra, *client_mod.HttpClient, *Item) void) type {
    return struct {
        extra: Extra,
        pool: *pool_mod.HttpClientPool,
        items: []Item,
        next: std.atomic.Value(usize) = .init(0),

        fn worker(q: *@This()) void {
            while (true) {
                const i = q.next.fetchAdd(1, .acq_rel);
                if (i >= q.items.len) return;
                const http = q.pool.acquire();
                defer q.pool.release(http);
                work(q.extra, http, &q.items[i]);
            }
        }
    };
}

const FetchExtra = struct { ctx: *const AppCtx, cache_dir: []const u8 };
const FetchQueue = WorkQueue(Fetch, FetchExtra, fetchOne);

fn fetchOne(x: FetchExtra, http: *client_mod.HttpClient, f: *Fetch) void {
    var api = api_mod.BrewApi.init(x.ctx.io, std.heap.smp_allocator, http, x.cache_dir);
    api.base_url = x.ctx.mirrors.api_base;
    api.offline = x.ctx.offline;
    f.body = api.fetchFormula(f.name) catch |e| {
        f.err = e;
        return;
    };
}

/// Runs `worker` on `count` threads over a shared queue, draining on this
/// thread when spawning fails; joins before returning.
fn fanOut(allocator: std.mem.Allocator, count: usize, comptime worker: anytype, queue: anytype) !void {
    const threads = try allocator.alloc(std.Thread, count);
    defer allocator.free(threads);
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    while (spawned < count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, worker, .{queue}) catch {
            // Out of threads is not out of luck: drain the queue on this one.
            worker(queue);
            break;
        };
    }
}

/// A cold Cellar is one request per formula; serially that is seconds of
/// silence, so fan out the way `outdated` does. Warm runs never leave the cache.
fn fetchAll(ctx: *const AppCtx, allocator: std.mem.Allocator, cache_dir: []const u8, pool: *pool_mod.HttpClientPool, fetches: []Fetch) !void {
    var queue: FetchQueue = .{ .extra = .{ .ctx = ctx, .cache_dir = cache_dir }, .pool = pool, .items = fetches };
    try fanOut(allocator, @min(pool.clients.len, fetches.len), FetchQueue.worker, &queue);
}

/// An installed keg attributed to a tap, with what the walk needs to find
/// its recipe without going back to the database.
const TapKeg = struct {
    name: []const u8,
    pkg_version: []const u8,
    /// Null for a keg recorded before the column existed; the tap's HEAD
    /// stands in for it.
    sha: ?[]const u8,
    /// Null when the tap's repository cannot be derived from its row or slug.
    urls: ?tap_mod.TapBaseUrls,
};

/// What one tap keg resolved to; filled by a worker, read on the main thread.
const TapFetch = struct {
    keg: TapKeg,
    outcome: enum { pending, identified, unidentified, failed } = .pending,
    /// OSV query key, sliced out of `buf`.
    repo_url: []const u8 = "",
    tag: []const u8 = "",
    /// Why the recipe could not be read, for the warning: a literal or `buf`.
    reason: []const u8 = "",
    buf: [768]u8 = undefined,

    fn fail(f: *TapFetch, reason: []const u8) void {
        f.outcome = .failed;
        f.reason = reason;
    }

    fn identified(f: *TapFetch, target: identify.Target) void {
        const n = target.repo_url.len + target.tag.len;
        if (n > f.buf.len) return f.fail("recipe source url too long");
        @memcpy(f.buf[0..target.repo_url.len], target.repo_url);
        @memcpy(f.buf[target.repo_url.len..n], target.tag);
        f.repo_url = f.buf[0..target.repo_url.len];
        f.tag = f.buf[target.repo_url.len..n];
        f.outcome = .identified;
    }
};

const TapExtra = struct { ctx: *const AppCtx, forge_base: ?[]const u8, tripped: *tap_mod.TrippedHosts };
const TapQueue = WorkQueue(TapFetch, TapExtra, resolveTapKeg);

/// Recipe at the installed commit -> source url -> OSV query key. Mirrors
/// the `outdated` tap audit's fetch shape; the parse and outcome stay here.
fn resolveTapKeg(x: TapExtra, http: *client_mod.HttpClient, f: *TapFetch) void {
    const urls = f.keg.urls orelse return f.fail("tap repository unknown");
    var head: ?tap_mod.HeadResolution = null;
    defer if (head) |*h| h.deinit();
    const sha = f.keg.sha orelse blk: {
        var head_url_buf: [512]u8 = undefined;
        const head_url = if (x.forge_base) |b|
            std.fmt.bufPrint(&head_url_buf, "{s}/commits/HEAD", .{b}) catch return f.fail("could not resolve the tap HEAD")
        else
            urls.api_head_url;
        // The tap resolve hint every other command shows (rate limit, token).
        head = tap_mod.resolveHeadCommit(x.ctx.io, x.ctx.environ, std.heap.smp_allocator, urls.forge, head_url, null) catch |e|
            return f.fail(tap_mod.describeResolveError(&f.buf, e, urls.forge, urls.host));
        break :blk head.?.sha orelse return f.fail("could not resolve the tap HEAD");
    };
    var fetch = tap_mod.fetchRawFile(http, x.ctx.environ, urls.forge, x.forge_base orelse urls.raw_base, sha, f.keg.name, tap_mod.keg_rb_subtrees, x.tripped) catch
        return f.fail("could not fetch the recipe");
    switch (fetch) {
        .not_found => return f.fail("recipe not found in the tap"),
        .found => |*resp| {
            defer resp.deinit();
            const rb = rb_parse.parseRubyFormula(resp.body) orelse return f.fail(if (rb_parse.optsOutOfChecksum(resp.body))
                "recipe " ++ rb_parse.checksum_opt_out_reason
            else
                "unreadable recipe");
            var buf: [512]u8 = undefined;
            const target = identify.identify(&buf, rb.url, rb.version) orelse {
                f.outcome = .unidentified;
                return;
            };
            f.identified(target);
        },
    }
}

fn resolveTapKegs(ctx: *const AppCtx, allocator: std.mem.Allocator, pool: *pool_mod.HttpClientPool, forge_base: ?[]const u8, fetches: []TapFetch) !void {
    if (fetches.len == 0) return;
    // One dead raw host is paid for once per run, not once per keg.
    var tripped = tap_mod.TrippedHosts{};
    var queue: TapQueue = .{ .extra = .{ .ctx = ctx, .forge_base = forge_base, .tripped = &tripped }, .pool = pool, .items = fetches };
    try fanOut(allocator, @min(pool.clients.len, fetches.len), TapQueue.worker, &queue);
}

/// Turns the resolved tap kegs into entries: one OSV batch for every
/// identified keg, then detail for the first `max_detail_fetches` hits.
/// Returns how many kegs no source could be derived for.
fn scanTapKegs(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    pool: *pool_mod.HttpClientPool,
    osv_base: []const u8,
    detail_cap: usize,
    fetches: []const TapFetch,
    entries: *std.ArrayList(Entry),
    unchecked: *std.ArrayList([]const u8),
) !usize {
    var not_covered: usize = 0;
    var targets: std.ArrayList(osv.Target) = .empty;
    var identified: std.ArrayList(*const TapFetch) = .empty;
    for (fetches) |*f| switch (f.outcome) {
        .identified => {
            try targets.append(arena, .{ .repo_url = f.repo_url, .tag = f.tag });
            try identified.append(arena, f);
        },
        // Quiet, like brew's skipped formulae: a non-forge source is not a failure.
        .unidentified => not_covered += 1,
        .failed => {
            output.warnAlways("{s}: {s}", .{ f.keg.name, f.reason });
            try unchecked.append(allocator, f.keg.name);
        },
        .pending => unreachable,
    };
    if (identified.items.len == 0) return not_covered;

    const http = pool.acquire();
    defer pool.release(http);
    const ids_per_keg = osv.queryBatch(http, arena, osv_base, targets.items) catch |e| {
        const noun: []const u8 = if (identified.items.len == 1) "keg" else "kegs";
        switch (e) {
            error.Canceled => return error.UserInterrupted,
            error.RateLimited => output.warnAlways("OSV rate limit reached; {d} tap {s} not checked, retry later", .{ identified.items.len, noun }),
            else => output.warnAlways("could not query OSV for {d} tap {s} ({s})", .{ identified.items.len, noun, @errorName(e) }),
        }
        for (identified.items) |f| try unchecked.append(allocator, f.keg.name);
        return not_covered;
    };

    var details: std.StringHashMapUnmanaged(osv.Advisory) = .empty;
    var fetched: usize = 0;
    for (identified.items, ids_per_keg) |f, ids| {
        const vulns = try arena.alloc(formula_mod.Vuln, ids.len);
        for (vulns, ids) |*v, id| {
            v.* = .{ .id = id, .upstream = &.{}, .severity = null, .summary = null };
            const gop = try details.getOrPut(arena, id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .id = id, .summary = null, .severity = null };
                if (fetched < detail_cap) {
                    fetched += 1;
                    // A missing detail leaves the id-only row; the hit itself stands.
                    if (osv.vulnerability(http, arena, osv_base, id)) |a| gop.value_ptr.* = a else |e| {
                        if (e == error.Canceled) return error.UserInterrupted;
                    }
                }
            }
            v.severity = gop.value_ptr.severity;
            v.summary = gop.value_ptr.summary;
        }
        try entries.append(allocator, .{
            .name = f.keg.name,
            .installed_version = f.keg.pkg_version,
            .formula = null,
            .vulns = vulns,
        });
    }
    return not_covered;
}

/// The core kegs (name -> pkg_version), the tap kegs with their repository
/// resolved, and how many kegs have no recipe to look up at all.
const Installed = struct {
    core: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    tap_kegs: std.ArrayList(TapKeg) = .empty,
    skipped: usize = 0,

    fn tapKeg(self: Installed, name: []const u8) ?TapKeg {
        for (self.tap_kegs.items) |keg| {
            if (std.mem.eql(u8, keg.name, name)) return keg;
        }
        return null;
    }
};

/// Everything on `arena`; the database is closed before this returns.
fn readInstalled(io: std.Io, arena: std.mem.Allocator) !Installed {
    var out: Installed = .{};
    const prefix = atomic.maltPrefixOrAbort();
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    // Only a missing `db/` reads as "nothing installed"; a database that is
    // there but will not open must never turn into a clean bill of health.
    var db = outdated.openPrefixDb(io, db_path) catch |e| switch (e) {
        error.Absent => return out,
        error.Unreadable => {
            output.err("cannot open {s}", .{db_path});
            return error.Aborted;
        },
    };
    defer db.close();
    schema.initSchema(&db) catch |e| return schema_report.abortInitFailure(&db, e, prefix);

    var stmt = try db.prepare("SELECT name, version, revision, tap, tap_commit_sha FROM kegs ORDER BY name;");
    defer stmt.finalize();
    while (try stmt.step()) {
        const name = std.mem.sliceTo(stmt.columnText(0) orelse continue, 0);
        const version = std.mem.sliceTo(stmt.columnText(1) orelse "", 0);
        var ver_buf: [256]u8 = undefined;
        const pkg = try arena.dupe(u8, try formula_mod.pkgVersion(&ver_buf, version, stmt.columnInt(2)));
        const tap = std.mem.sliceTo(stmt.columnText(3) orelse "", 0);
        if (install_args.isCoreTap(tap)) {
            try out.core.put(arena, try arena.dupe(u8, name), pkg);
            continue;
        }
        // A --local keg (or any label that is not a slug) has no tap to ask.
        const slash = std.mem.indexOfScalar(u8, tap, '/') orelse {
            out.skipped += 1;
            continue;
        };
        const slug_ok = slash > 0 and slash < tap.len - 1;
        const sha_col: ?[]const u8 = if (stmt.columnText(4)) |c| std.mem.sliceTo(c, 0) else null;
        try out.tap_kegs.append(arena, .{
            .name = try arena.dupe(u8, name),
            .pkg_version = pkg,
            .sha = if (sha_col) |c| (if (c.len > 0) try arena.dupe(u8, c) else null) else null,
            .urls = if (slug_ok) tap_mod.resolveTapBaseUrls(arena, &db, tap) catch null else null,
        });
    }
    return out;
}

fn allClearMessage(buf: []u8, checked: usize, unchecked: usize) []const u8 {
    if (checked == 0) return if (unchecked == 0) "No formulae installed." else "No formulae could be checked.";
    const noun: []const u8 = if (checked == 1) "formula" else "formulae";
    return std.fmt.bufPrint(buf, "No open advisories for {d} {s}.", .{ checked, noun }) catch "No open advisories.";
}

/// A cold cache pays one API fetch per formula plus the tap and OSV round
/// trips, so say what the wait is for. Null when there is nothing to fetch.
fn checkingMessage(buf: []u8, core: usize, taps: usize) ?[]const u8 {
    if (core == 0 and taps == 0) return null;
    const core_noun: []const u8 = if (core == 1) "formula" else "formulae";
    const tap_noun: []const u8 = if (taps == 1) "tap formula" else "tap formulae";
    const msg = if (taps == 0)
        std.fmt.bufPrint(buf, "Checking {d} {s}...", .{ core, core_noun })
    else if (core == 0)
        std.fmt.bufPrint(buf, "Checking {d} {s}...", .{ taps, tap_noun })
    else
        std.fmt.bufPrint(buf, "Checking {d} {s} and {d} {s}...", .{ core, core_noun, taps, tap_noun });
    return msg catch "Checking...";
}

fn coverageMessage(buf: []u8, skipped: usize) ?[]const u8 {
    if (skipped == 0) return null;
    const one = skipped == 1;
    return std.fmt.bufPrint(buf, "{d} local or unidentifiable {s} not covered: no advisory source for {s}.", .{
        skipped, @as([]const u8, if (one) "keg" else "kegs"), @as([]const u8, if (one) "it" else "them"),
    }) catch null;
}

fn writeHuman(w: *std.Io.Writer, rows: []const Row) !void {
    var name_w: usize = 0;
    var id_w: usize = 0;
    for (rows) |r| {
        name_w = @max(name_w, cleanLen(r.name));
        id_w = @max(id_w, cleanLen(r.vuln.id));
    }
    for (rows) |r| {
        const name_n = try writeClean(w, r.name);
        try w.splatByteAll(' ', name_w - name_n + 2);
        const sev_n = try writeClean(w, r.vuln.severity orelse "-");
        try w.splatByteAll(' ', "critical".len - @min(sev_n, "critical".len) + 2);
        const id_n = try writeClean(w, r.vuln.id);
        if (r.vuln.summary) |summary| {
            try w.splatByteAll(' ', id_w - id_n + 2);
            _ = try writeClean(w, summary);
        }
        try w.writeAll("\n");
    }
}

/// API text is tap-sourced free text: drop anything a terminal could act on
/// (the `info` rule) and flatten line breaks so a row stays one line.
fn writeClean(w: *std.Io.Writer, s: []const u8) !usize {
    var st: term_sanitize.Utf8State = .{};
    var n: usize = 0;
    for (s) |b| {
        if (!term_sanitize.passableByte(b, &st)) continue;
        try w.writeByte(if (b == '\n' or b == '\t') ' ' else b);
        n += 1;
    }
    return n;
}

/// Width a value will take after `writeClean`, for column alignment.
fn cleanLen(s: []const u8) usize {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    return writeClean(&sink.writer, s) catch unreachable;
}

/// `{"schema_version":1,"not_covered":N,"unchecked":[...],"formulae":[{"name","installed_version","open":[...]}]}`;
/// every checked formula is listed so a clean one reads as `open: []`, and
/// `unchecked` names the ones whose metadata never arrived.
fn writeJson(w: *std.Io.Writer, r: Report) !void {
    try w.print("{{\"schema_version\":1,\"not_covered\":{d},\"unchecked\":", .{r.not_covered});
    try output.jsonStringArray(w, r.unchecked);
    try w.writeAll(",\"formulae\":[");
    for (r.entries, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, e.name);
        try w.writeAll(",\"installed_version\":");
        if (e.installed_version) |v| try output.jsonStr(w, v) else try w.writeAll("null");
        try w.writeAll(",\"open\":[");
        var first = true;
        for (r.rows) |row| {
            if (!std.mem.eql(u8, row.name, e.name)) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"id\":");
            try output.jsonStr(w, row.vuln.id);
            try w.writeAll(",\"upstream\":");
            try output.jsonStringArray(w, row.vuln.upstream);
            try w.writeAll(",\"severity\":");
            if (row.vuln.severity) |sv| try output.jsonStr(w, sv) else try w.writeAll("null");
            try w.writeAll(",\"summary\":");
            if (row.vuln.summary) |sm| try output.jsonStr(w, sm) else try w.writeAll("null");
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}\n");
}

/// Ordered so `@intFromEnum` compares as "more severe".
pub const Severity = enum(u2) { low, medium, high, critical };

const severity_labels = std.StaticStringMap(Severity).initComptime(.{
    .{ "low", .low },
    .{ "medium", .medium },
    .{ "high", .high },
    .{ "critical", .critical },
});

/// Rank of an advisory. Anything the API does not label with one of the
/// four words ranks lowest so it still surfaces instead of being filtered out.
pub fn severityOf(label: ?[]const u8) Severity {
    return severity_labels.get(label orelse return .low) orelse .low;
}

pub fn parseSeverityFlag(arg: []const u8) ?Severity {
    return severity_labels.get(arg);
}

/// True when `v` is at least `min` severe; no `min` keeps everything.
pub fn keeps(min: ?Severity, v: formula_mod.Vuln) bool {
    const floor = min orelse return true;
    return @intFromEnum(severityOf(v.severity)) >= @intFromEnum(floor);
}

/// One reported advisory. `name` is the installed formula; `vuln` borrows
/// from that formula's parse and must not outlive it.
pub const Row = struct {
    name: []const u8,
    vuln: formula_mod.Vuln,
};

/// Most severe first, then name, then id - a stable order for scripts to diff.
pub fn rowLessThan(_: void, a: Row, b: Row) bool {
    const sa = @intFromEnum(severityOf(a.vuln.severity));
    const sb = @intFromEnum(severityOf(b.vuln.severity));
    if (sa != sb) return sa > sb;
    return switch (std.mem.order(u8, a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.vuln.id, b.vuln.id) == .lt,
    };
}

/// `brew vulns` parity: rows exit 1 so scripts can gate on it, and a scan
/// that could not check every formula exits 2 so it is never mistaken for
/// either a clean run or a mere finding. The rows and warnings are the
/// message; nothing more is printed.
pub fn exitStatus(reported: usize, unchecked: usize) error{ Aborted, ScanIncomplete }!void {
    if (unchecked > 0) return error.ScanIncomplete;
    if (reported > 0) return error.Aborted;
}

// --- inline unit tests --------------------------------------------------

const testing = std.testing;

fn vuln(id: []const u8, severity: ?[]const u8) formula_mod.Vuln {
    return .{ .id = id, .upstream = &.{}, .severity = severity, .summary = null };
}

test "severityOf ranks the four labels and reads anything else as low" {
    try testing.expectEqual(Severity.critical, severityOf("critical"));
    try testing.expectEqual(Severity.high, severityOf("high"));
    try testing.expectEqual(Severity.medium, severityOf("medium"));
    try testing.expectEqual(Severity.low, severityOf("low"));
    // Unknown strings and a missing field must surface, never hide.
    try testing.expectEqual(Severity.low, severityOf("moderate"));
    try testing.expectEqual(Severity.low, severityOf(null));
}

test "parseSeverityFlag accepts the four labels only" {
    try testing.expectEqual(Severity.high, parseSeverityFlag("high").?);
    try testing.expectEqual(Severity.critical, parseSeverityFlag("critical").?);
    try testing.expect(parseSeverityFlag("HIGH") == null);
    try testing.expect(parseSeverityFlag("") == null);
}

test "--severity=high keeps high and critical only" {
    const min = Severity.high;
    try testing.expect(keeps(min, vuln("a", "critical")));
    try testing.expect(keeps(min, vuln("b", "high")));
    try testing.expect(!keeps(min, vuln("c", "medium")));
    try testing.expect(!keeps(min, vuln("d", "low")));
    try testing.expect(!keeps(min, vuln("e", null)));
    try testing.expect(!keeps(min, vuln("f", "unknown")));
    // No filter keeps everything, including the unranked.
    try testing.expect(keeps(null, vuln("g", null)));
}

test "rows sort by severity first, then name, then id" {
    var rows = [_]Row{
        .{ .name = "zeta", .vuln = vuln("Z-1", "low") },
        .{ .name = "beta", .vuln = vuln("B-2", "high") },
        .{ .name = "beta", .vuln = vuln("B-1", "high") },
        .{ .name = "alpha", .vuln = vuln("A-1", null) },
        .{ .name = "gamma", .vuln = vuln("G-1", "critical") },
    };
    std.mem.sort(Row, &rows, {}, rowLessThan);
    try testing.expectEqualStrings("G-1", rows[0].vuln.id);
    try testing.expectEqualStrings("B-1", rows[1].vuln.id);
    try testing.expectEqualStrings("B-2", rows[2].vuln.id);
    // Unranked ties with low and falls back to the name order.
    try testing.expectEqualStrings("A-1", rows[3].vuln.id);
    try testing.expectEqualStrings("Z-1", rows[4].vuln.id);
}

test "human rows scrub terminal escapes smuggled through API text" {
    // The summary is free text from the tap; an escape in it would otherwise
    // reach the terminal verbatim, the way `info` already guards `desc`.
    var rows = [_]Row{.{
        .name = "x",
        .vuln = .{
            .id = "ID-\x1b[2J",
            .upstream = &.{},
            .severity = "high\x9b31m",
            .summary = "plain \x1b]0;title\x07text\r\n",
        },
    }};
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeHuman(&aw.writer, &rows);
    try testing.expectEqualStrings("x  high31m   ID-[2J  plain ]0;titletext \n", aw.written());
}

test "the all-clear line says how many formulae were checked" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("No open advisories for 65 formulae.", allClearMessage(&buf, 65, 0));
    try testing.expectEqualStrings("No open advisories for 1 formula.", allClearMessage(&buf, 1, 2));
    // An empty walk is not a clean bill of health; say what was there.
    try testing.expectEqualStrings("No formulae installed.", allClearMessage(&buf, 0, 0));
    // Nothing checked because every fetch failed is not "nothing installed".
    try testing.expectEqualStrings("No formulae could be checked.", allClearMessage(&buf, 0, 3));
}

test "the checking line counts what is about to be fetched, or stays silent" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Checking 69 formulae...", checkingMessage(&buf, 69, 0).?);
    try testing.expectEqualStrings("Checking 1 formula...", checkingMessage(&buf, 1, 0).?);
    try testing.expectEqualStrings("Checking 65 formulae and 4 tap formulae...", checkingMessage(&buf, 65, 4).?);
    try testing.expectEqualStrings("Checking 1 tap formula...", checkingMessage(&buf, 0, 1).?);
    // Nothing to fetch means nothing to wait for; the all-clear line speaks.
    try testing.expect(checkingMessage(&buf, 0, 0) == null);
}

test "the coverage line is only written when something was skipped" {
    var buf: [128]u8 = undefined;
    try testing.expect(coverageMessage(&buf, 0) == null);
    try testing.expectEqualStrings(
        "1 local or unidentifiable keg not covered: no advisory source for it.",
        coverageMessage(&buf, 1).?,
    );
    try testing.expectEqualStrings(
        "3 local or unidentifiable kegs not covered: no advisory source for them.",
        coverageMessage(&buf, 3).?,
    );
}

test "exit distinguishes open advisories from an incomplete scan" {
    try exitStatus(0, 0);
    try testing.expectError(error.Aborted, exitStatus(1, 0));
    try testing.expectError(error.Aborted, exitStatus(8, 0));
    // A scan that could not check everything must not pass as either clean
    // or merely "found something": incomplete wins.
    try testing.expectError(error.ScanIncomplete, exitStatus(0, 1));
    try testing.expectError(error.ScanIncomplete, exitStatus(8, 1));
}

test "the stale-keg notice fires only for a keg behind upstream that has open rows" {
    var buf: [160]u8 = undefined;
    const rows = [_]Row{.{ .name = "abcde", .vuln = vuln("X", "high") }};
    try testing.expectEqualStrings(
        "abcde: open at 2.9.3_1; installed 2.9.2 may carry more",
        staleNotice(&buf, "abcde", "2.9.3_1", "2.9.2", &rows).?,
    );
    // Same version: nothing to caveat.
    try testing.expect(staleNotice(&buf, "abcde", "2.9.2", "2.9.2", &rows) == null);
    // Not installed (explicitly named): nothing to compare against.
    try testing.expect(staleNotice(&buf, "abcde", "2.9.3_1", null, &rows) == null);
    // Behind, but clean: no rows to be "more" than.
    try testing.expect(staleNotice(&buf, "curl", "8.17", "8.16", &rows) == null);
}
