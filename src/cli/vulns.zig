//! malt — vulns command
//! Report open advisories for installed formulae from the formula API.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const formula_mod = @import("../core/formula.zig");
const signals = @import("../core/signals.zig");
const schema = @import("../db/schema.zig");
const schema_report = @import("schema_report.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const api_mod = @import("../net/api.zig");
const pool_mod = @import("../net/client_pool.zig");
const outdated = @import("outdated.zig");
const refresh = @import("outdated/refresh.zig");
const output = @import("../ui/output.zig");
const term_sanitize = @import("../ui/term_sanitize.zig");
const help = @import("help.zig");
const install_args = @import("install/args.zig");

/// One queried formula with its parse kept alive for the rows that borrow it.
const Entry = struct {
    name: []const u8,
    /// Null when the name was asked for on the command line but is not installed.
    installed_version: ?[]const u8,
    formula: formula_mod.Formula,
};

/// Everything the writers need, so human and JSON output share one call.
const Report = struct {
    entries: []const Entry,
    rows: []const Row,
    /// Names whose metadata could not be fetched; the scan is incomplete.
    unchecked: []const []const u8,
    /// Tap and --local kegs the implicit walk left out.
    not_covered: usize,
};

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
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

    // Installed core formula -> pkg_version. Tap and --local kegs have no
    // entry in the formula API, so they are never walked implicitly.
    var installed: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    const skipped_kegs = try readInstalled(ctx.io, arena, &installed);
    const walk_all = names.items.len == 0;
    const targets: []const []const u8 = if (walk_all) installed.keys() else names.items;

    const fetches = try allocator.alloc(Fetch, targets.len);
    defer {
        for (fetches) |f| if (f.body) |b| std.heap.smp_allocator.free(b);
        allocator.free(fetches);
    }
    for (fetches, targets) |*f, name| f.* = .{ .name = name };
    const cache_dir = try atomic.maltCacheDir(allocator);
    defer allocator.free(cache_dir);
    try fetchAll(ctx, allocator, cache_dir, fetches);
    // Cancelled fetches all fail alike; the interrupt is the real story.
    if (signals.isInterrupted()) return error.UserInterrupted;

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*e| e.formula.deinit();
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
            .installed_version = installed.get(name),
            .formula = f,
        });
    }

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    for (entries.items) |e| {
        for (e.formula.vulns_open) |v| {
            if (keeps(min_severity, v)) try rows.append(allocator, .{ .name = e.name, .vuln = v });
        }
    }
    std.mem.sort(Row, rows.items, {}, rowLessThan);

    try report(ctx, .{
        .entries = entries.items,
        .rows = rows.items,
        .unchecked = unchecked.items,
        // Coverage only matters when the user asked for "everything installed".
        .not_covered = if (walk_all) skipped_kegs else 0,
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
        if (staleNotice(&msg_buf, e.name, e.formula.pkg_version, e.installed_version, r.rows)) |msg|
            output.warnAlways("{s}", .{msg});
    }
    // Silence reads as "did it run?"; say what was checked, like `outdated`.
    if (r.rows.len == 0) output.info("{s}", .{allClearMessage(&msg_buf, r.entries.len)});
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

const FetchQueue = struct {
    ctx: *const AppCtx,
    cache_dir: []const u8,
    pool: *pool_mod.HttpClientPool,
    fetches: []Fetch,
    next: std.atomic.Value(usize) = .init(0),

    fn worker(q: *FetchQueue) void {
        while (true) {
            const i = q.next.fetchAdd(1, .acq_rel);
            if (i >= q.fetches.len) return;
            const http = q.pool.acquire();
            defer q.pool.release(http);
            var api = api_mod.BrewApi.init(q.ctx.io, std.heap.smp_allocator, http, q.cache_dir);
            api.base_url = q.ctx.mirrors.api_base;
            api.offline = q.ctx.offline;
            const f = &q.fetches[i];
            f.body = api.fetchFormula(f.name) catch |e| {
                f.err = e;
                continue;
            };
        }
    }
};

/// A cold Cellar is one request per formula; serially that is seconds of
/// silence, so fan out the way `outdated` does. Warm runs never leave the cache.
fn fetchAll(ctx: *const AppCtx, allocator: std.mem.Allocator, cache_dir: []const u8, fetches: []Fetch) !void {
    const workers = refresh.outdatedWorkerCount(fetches.len, null);
    var pool = try pool_mod.HttpClientPool.init(ctx.io, ctx.environ, allocator, workers);
    defer pool.deinit();
    pool.setOfflineAll(ctx.offline);

    var queue: FetchQueue = .{ .ctx = ctx, .cache_dir = cache_dir, .pool = &pool, .fetches = fetches };
    const threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(threads);
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    while (spawned < workers) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, FetchQueue.worker, .{&queue}) catch {
            // Out of threads is not out of luck: drain the queue on this one.
            FetchQueue.worker(&queue);
            break;
        };
    }
}

/// Fills `out` with the core kegs and returns how many tap or --local kegs
/// were left out, so the summary can say what the report did not cover.
fn readInstalled(io: std.Io, arena: std.mem.Allocator, out: *std.StringArrayHashMapUnmanaged([]const u8)) !usize {
    const prefix = atomic.maltPrefixOrAbort();
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    // Only a missing `db/` reads as "nothing installed"; a database that is
    // there but will not open must never turn into a clean bill of health.
    var db = outdated.openPrefixDb(io, db_path) catch |e| switch (e) {
        error.Absent => return 0,
        error.Unreadable => {
            output.err("cannot open {s}", .{db_path});
            return error.Aborted;
        },
    };
    defer db.close();
    schema.initSchema(&db) catch |e| return schema_report.abortInitFailure(&db, e, prefix);

    var skipped: usize = 0;
    var stmt = try db.prepare("SELECT name, version, revision, tap FROM kegs ORDER BY name;");
    defer stmt.finalize();
    while (try stmt.step()) {
        const tap = std.mem.sliceTo(stmt.columnText(3) orelse "", 0);
        if (!install_args.isCoreTap(tap)) {
            skipped += 1;
            continue;
        }
        const name = std.mem.sliceTo(stmt.columnText(0) orelse continue, 0);
        const version = std.mem.sliceTo(stmt.columnText(1) orelse "", 0);
        var ver_buf: [256]u8 = undefined;
        const pkg = try formula_mod.pkgVersion(&ver_buf, version, stmt.columnInt(2));
        try out.put(arena, try arena.dupe(u8, name), try arena.dupe(u8, pkg));
    }
    return skipped;
}

fn allClearMessage(buf: []u8, checked: usize) []const u8 {
    if (checked == 0) return "No formulae installed.";
    const noun: []const u8 = if (checked == 1) "formula" else "formulae";
    return std.fmt.bufPrint(buf, "No open advisories for {d} {s}.", .{ checked, noun }) catch "No open advisories.";
}

fn coverageMessage(buf: []u8, skipped: usize) ?[]const u8 {
    if (skipped == 0) return null;
    const one = skipped == 1;
    return std.fmt.bufPrint(buf, "{d} tap or local {s} not covered: the API has no advisory data for {s}.", .{
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
    try testing.expectEqualStrings("No open advisories for 65 formulae.", allClearMessage(&buf, 65));
    try testing.expectEqualStrings("No open advisories for 1 formula.", allClearMessage(&buf, 1));
    // An empty walk is not a clean bill of health; say what was there.
    try testing.expectEqualStrings("No formulae installed.", allClearMessage(&buf, 0));
}

test "the coverage line is only written when something was skipped" {
    var buf: [128]u8 = undefined;
    try testing.expect(coverageMessage(&buf, 0) == null);
    try testing.expectEqualStrings(
        "1 tap or local keg not covered: the API has no advisory data for it.",
        coverageMessage(&buf, 1).?,
    );
    try testing.expectEqualStrings(
        "3 tap or local kegs not covered: the API has no advisory data for them.",
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
