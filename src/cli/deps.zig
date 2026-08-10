//! malt — deps command
//! Show what a formula depends on (forward direction of `mt uses`).

const std = @import("std");
const testing = std.testing;

const AppCtx = @import("../app_ctx.zig").AppCtx;
const formula_mod = @import("../core/formula.zig");
const signals = @import("../core/signals.zig");
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
const cli_info = @import("info.zig");
const help = @import("help.zig");

pub const DepError = error{
    OutOfMemory,
    Aborted,
};

/// A single node in the dependency graph: a formula and the names it
/// depends on directly. Returned by `collectDeps` and consumed by the
/// human and JSON encoders.
pub const Entry = struct {
    formula: []const u8,
    depends_on: [][]const u8,
};

pub const Options = struct {
    recursive: bool = false,
};

/// Pluggable dep source — either the local DB (installed kegs) or the
/// upstream API (uninstalled formulas). The `fetchFn` returns owned
/// strings the caller must free, or null when the source has no record
/// of this name.
pub const DepLookup = struct {
    ctx: *anyopaque,
    fetchFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?[][]const u8,

    pub fn fetch(self: DepLookup, allocator: std.mem.Allocator, name: []const u8) !?[][]const u8 {
        return self.fetchFn(self.ctx, allocator, name);
    }
};

/// Collect the dep graph rooted at `root` as a flat array of entries.
///
/// Resolution policy per name:
///   1. Try `db` first — when it hits, the entry is "installed".
///   2. On miss, try `api` if provided (null = `--installed` mode).
///   3. Unresolved root: returns an empty slice (the caller renders
///      "not found"); unresolved transitive deps are simply not walked.
///
/// Caller owns the returned slice and every string inside it; use
/// `freeEntries` to drop them.
pub fn collectDeps(
    allocator: std.mem.Allocator,
    db: DepLookup,
    api: ?DepLookup,
    root: []const u8,
    opts: Options,
) DepError![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer freeEntriesList(allocator, &entries);

    // `visited` borrows from `entries[*].formula`. Strings live as long as
    // entries do, so no extra dupe is needed for the key set.
    var visited: std.StringHashMap(void) = .init(allocator);
    defer visited.deinit();

    // BFS frontier of names still to expand. Each pushed name is the
    // formula on the current entry — same lifetime as `entries`.
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(allocator);

    try appendEntry(allocator, &entries, &visited, &frontier, db, api, root);

    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        // One lookup per node, each possibly a network fetch. `execute` turns
        // the partial graph into a non-zero exit rather than rendering it.
        if (signals.isInterrupted()) break;
        if (!opts.recursive) break;
        const current = frontier.items[head];
        const idx = entryIndex(entries.items, current) orelse continue;
        for (entries.items[idx].depends_on) |dep| {
            try appendEntry(allocator, &entries, &visited, &frontier, db, api, dep);
        }
    }

    return entries.toOwnedSlice(allocator) catch DepError.OutOfMemory;
}

/// Resolve `name` via db (then api) and append one entry. Already-visited
/// names are skipped. Unresolved names are silently dropped — the BFS
/// caller doesn't error on a transitive miss.
fn appendEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    visited: *std.StringHashMap(void),
    frontier: *std.ArrayList([]const u8),
    db: DepLookup,
    api: ?DepLookup,
    name: []const u8,
) DepError!void {
    if (visited.contains(name)) return;

    const deps = (try fetchEither(allocator, db, api, name)) orelse return;
    const formula_owned = allocator.dupe(u8, name) catch {
        freeOwnedDeps(allocator, deps);
        return DepError.OutOfMemory;
    };
    errdefer allocator.free(formula_owned);

    try entries.append(allocator, .{ .formula = formula_owned, .depends_on = deps });
    visited.put(formula_owned, {}) catch {};
    try frontier.append(allocator, formula_owned);
}

fn fetchEither(
    allocator: std.mem.Allocator,
    db: DepLookup,
    api: ?DepLookup,
    name: []const u8,
) DepError!?[][]const u8 {
    if (db.fetch(allocator, name) catch |e| return mapLookupErr(e)) |deps| return deps;
    const api_src = api orelse return null;
    return api_src.fetch(allocator, name) catch |e| return mapLookupErr(e);
}

/// Preserve OOM up the stack so the caller's allocator-failure tests
/// see the right error; everything else (DB closed, parse failure)
/// surfaces as `Aborted` so the user gets a single exit code, not a
/// noisy backtrace through unrelated internals.
fn mapLookupErr(e: anyerror) DepError {
    return switch (e) {
        error.OutOfMemory => DepError.OutOfMemory,
        else => DepError.Aborted,
    };
}

fn entryIndex(entries: []const Entry, name: []const u8) ?usize {
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.formula, name)) return i;
    }
    return null;
}

fn freeOwnedDeps(allocator: std.mem.Allocator, deps: [][]const u8) void {
    for (deps) |d| allocator.free(d);
    allocator.free(deps);
}

fn freeEntriesList(allocator: std.mem.Allocator, list: *std.ArrayList(Entry)) void {
    for (list.items) |e| {
        allocator.free(e.formula);
        for (e.depends_on) |d| allocator.free(d);
        allocator.free(e.depends_on);
    }
    list.deinit(allocator);
}

/// Free every string + slice owned by entries produced by `collectDeps`.
pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        allocator.free(e.formula);
        for (e.depends_on) |d| allocator.free(d);
        allocator.free(e.depends_on);
    }
    allocator.free(entries);
}

/// Emit an indented tree rooted at `root`. With `recursive=false` only
/// the root's direct deps are listed; with `recursive=true` the walk
/// follows each `Entry.depends_on` row by row, depth-indenting children
/// and marking missing dependencies (those without an entry of their
/// own) so `--installed -r` makes the dropped branches visible.
pub fn encodeHuman(
    w: *std.Io.Writer,
    root: []const u8,
    entries: []const Entry,
    recursive: bool,
) !void {
    if (entries.len == 0) {
        // Root resolved nowhere — neither installed nor known to the API
        // (or `--installed` was set and the keg isn't local). Differs
        // from the "found with no deps" path below.
        try w.writeAll(root);
        try w.writeAll(": not found.\n");
        return;
    }

    // Root resolved but advertises no direct deps — say so explicitly
    // rather than emitting a bare name line, which would read like the
    // command silently dropped the rest of the output.
    if (entryIndex(entries, root)) |idx| {
        if (entries[idx].depends_on.len == 0) {
            try w.writeAll(root);
            try w.writeAll(" has no dependencies.\n");
            return;
        }
    }

    // Ancestor chain along the current render path — used only to halt
    // re-recursion on a cycle (already-rendered leaf back-edge is fine).
    // 64 levels is well past any realistic dep tree; deeper graphs just
    // stop recursing and the back-edge guard still fires for shallower
    // cycles.
    var path_buf: [64][]const u8 = undefined;
    try renderNode(w, root, entries, recursive, 0, &path_buf, 0);
}

fn renderNode(
    w: *std.Io.Writer,
    name: []const u8,
    entries: []const Entry,
    recursive: bool,
    depth: usize,
    path: *[64][]const u8,
    path_len: usize,
) !void {
    try writeIndent(w, depth);
    try w.writeAll(name);

    const idx = entryIndex(entries, name) orelse {
        try w.writeAll(" (not installed)\n");
        return;
    };
    try w.writeAll("\n");

    if (!recursive) {
        // Non-recursive: emit direct deps as leaves. We never walked
        // them, so the absence of an entry is expected — annotating
        // "(not installed)" here would be noise.
        for (entries[idx].depends_on) |d| {
            try writeIndent(w, depth + 1);
            try w.writeAll(d);
            try w.writeAll("\n");
        }
        return;
    }

    // Back-edge: this name is currently expanding higher in the stack,
    // already rendered as a leaf above; do not recurse again.
    if (containsName(path[0..path_len], name)) return;
    if (path_len == path.len) return;
    path[path_len] = name;

    for (entries[idx].depends_on) |d| {
        try renderNode(w, d, entries, recursive, depth + 1, path, path_len + 1);
    }
}

fn containsName(stack: []const []const u8, name: []const u8) bool {
    for (stack) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

fn writeIndent(w: *std.Io.Writer, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
}

/// Emit `[{"formula":"…","depends_on":["…",…]},…]\n`.
pub fn encodeJson(w: *std.Io.Writer, entries: []const Entry) !void {
    try w.writeAll("[");
    for (entries, 0..) |e, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"formula\":");
        try output.jsonStr(w, e.formula);
        try w.writeAll(",\"depends_on\":[");
        for (e.depends_on, 0..) |d, j| {
            if (j != 0) try w.writeAll(",");
            try output.jsonStr(w, d);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]\n");
}

// --- DB adapter: dependencies table → DepLookup -----------------------------

/// Build a `DepLookup` that reads the local kegs/dependencies tables.
/// Returns null for any keg that isn't installed; returns an empty
/// slice for an installed leaf so the walker still emits a node for it.
pub fn dbDepLookup(db: *sqlite.Database) DepLookup {
    return .{ .ctx = @ptrCast(db), .fetchFn = dbFetch };
}

fn dbFetch(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[][]const u8 {
    const db: *sqlite.Database = @ptrCast(@alignCast(ctx));

    // First check the keg row exists — distinguishes "installed leaf"
    // (empty deps) from "not installed" (null), which the renderer
    // relies on to pick "(not installed)" vs the bare-leaf path.
    var keg_stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return null;
    defer keg_stmt.finalize();
    keg_stmt.bindText(1, name) catch return null;
    if (!(keg_stmt.step() catch false)) return null;
    const keg_id = keg_stmt.columnInt(0);

    var stmt = db.prepare(
        "SELECT dep_name FROM dependencies WHERE keg_id = ?1 ORDER BY dep_name;",
    ) catch return null;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return null;

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    while (stmt.step() catch false) {
        const raw = stmt.columnText(0) orelse continue;
        const dep = std.mem.sliceTo(raw, 0);
        const owned = try allocator.dupe(u8, dep);
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
    }

    return try out.toOwnedSlice(allocator);
}

// --- API adapter: BrewApi.fetchFormula → DepLookup --------------------------

const ApiCtx = struct {
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
};

/// Build a `DepLookup` that fetches + parses formula JSON from the API.
/// Returns null on any network/parse failure so the walker degrades to
/// "skip this branch" rather than aborting.
pub fn apiDepLookup(ctx: *ApiCtx) DepLookup {
    return .{ .ctx = @ptrCast(ctx), .fetchFn = apiFetch };
}

fn apiFetch(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[][]const u8 {
    const ac: *ApiCtx = @ptrCast(@alignCast(ctx));
    const body = ac.api.fetchFormula(name) catch return null;
    defer ac.allocator.free(body);

    var f = formula_mod.parseFormula(allocator, body) catch return null;
    defer f.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    for (f.dependencies) |d| {
        const owned = try allocator.dupe(u8, d);
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
    }
    return try out.toOwnedSlice(allocator);
}

// --- CLI dispatch -----------------------------------------------------------

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "deps")) return;

    // `--json` and `--quiet` are consumed by the global parser — they
    // never reach `args` here. Local flags only.
    var recursive = false;
    var installed_only = false;
    var target: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--recursive") or std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--installed")) {
            installed_only = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (target == null) target = arg;
        }
    }

    const name = target orelse {
        output.err("Usage: mt deps <formula>", .{});
        return error.Aborted;
    };

    const json_mode = output.isJson();

    const prefix = atomic.maltPrefixOrAbort();
    var db_opt: ?sqlite.Database = cli_info.openDb(prefix);
    defer if (db_opt) |*d| d.close();
    if (db_opt) |*db| schema.initSchema(db) catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = ctx.stdout.writer(ctx.io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    defer stdout.flush() catch {};

    const empty_entries: []Entry = &.{};
    const entries: []Entry = collectGraph(allocator, ctx, db_opt, name, .{
        .recursive = recursive,
        .installed_only = installed_only,
    }) catch empty_entries;
    defer freeEntries(allocator, entries);

    if (signals.isInterrupted()) {
        output.warn("Interrupted.", .{});
        return error.UserInterrupted;
    }

    if (json_mode) {
        try encodeJson(stdout, entries);
    } else {
        try encodeHuman(stdout, name, entries, recursive);
    }
}

/// Compose DB + (optional) API lookups for the current run and dispatch
/// to `collectDeps`. Split from `execute` so the lifetime story for
/// `BrewApi`/`HttpClient`/cache_dir stays scoped to one place.
fn collectGraph(
    allocator: std.mem.Allocator,
    ctx: *const AppCtx,
    db_opt: ?sqlite.Database,
    name: []const u8,
    opts: struct { recursive: bool, installed_only: bool },
) ![]Entry {
    var db_storage: sqlite.Database = undefined;
    var db_lookup: DepLookup = .{ .ctx = undefined, .fetchFn = alwaysMiss };
    if (db_opt) |db| {
        db_storage = db;
        db_lookup = dbDepLookup(&db_storage);
    }

    if (opts.installed_only) {
        return collectDeps(allocator, db_lookup, null, name, .{ .recursive = opts.recursive });
    }

    const cache_dir = atomic.maltCacheDir(allocator) catch {
        // No usable cache → only the DB is available, like --installed.
        return collectDeps(allocator, db_lookup, null, name, .{ .recursive = opts.recursive });
    };
    defer allocator.free(cache_dir);

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    http.offline = ctx.offline;
    var api = api_mod.BrewApi.init(ctx.io, allocator, &http, cache_dir);
    api.base_url = ctx.mirrors.api_base;
    api.offline = ctx.offline;
    var api_ctx = ApiCtx{ .allocator = allocator, .api = &api };
    const api_lookup = apiDepLookup(&api_ctx);

    return collectDeps(allocator, db_lookup, api_lookup, name, .{ .recursive = opts.recursive });
}

fn alwaysMiss(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?[][]const u8 {
    return null;
}

// --- unit tests for the pure helpers ----------------------------------------

/// In-memory `DepLookup` for the tests below. Maps a formula name to its
/// direct deps; tests use one for the DB role and another for the API
/// role to exercise the fallback policy of `collectDeps` without a real
/// SQLite DB or upstream network call.
const StubLookup = struct {
    map: std.StringHashMap([]const []const u8),

    fn init(alloc: std.mem.Allocator) StubLookup {
        return .{ .map = .init(alloc) };
    }

    fn deinit(self: *StubLookup) void {
        self.map.deinit();
    }

    fn add(self: *StubLookup, name: []const u8, deps: []const []const u8) !void {
        try self.map.put(name, deps);
    }

    fn fetch(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[][]const u8 {
        const self: *StubLookup = @ptrCast(@alignCast(ctx));
        const slice = self.map.get(name) orelse return null;

        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| allocator.free(s);
            out.deinit(allocator);
        }
        for (slice) |s| {
            const owned = try allocator.dupe(u8, s);
            errdefer allocator.free(owned);
            try out.append(allocator, owned);
        }
        return try out.toOwnedSlice(allocator);
    }

    fn lookup(self: *StubLookup) DepLookup {
        return .{ .ctx = @ptrCast(self), .fetchFn = StubLookup.fetch };
    }
};

fn sortEntriesByName(entries: []Entry) void {
    const cmp = struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.formula, b.formula);
        }
    }.lt;
    std.mem.sort(Entry, entries, {}, cmp);
}

fn findEntryByName(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.formula, name)) return e;
    }
    return null;
}

test "collectDeps emits root with direct deps from the db source" {
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    try db_stub.add("wget", &.{"openssl@3"});
    try db_stub.add("openssl@3", &.{});

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        null,
        "wget",
        .{},
    );
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("wget", entries[0].formula);
    try testing.expectEqual(@as(usize, 1), entries[0].depends_on.len);
    try testing.expectEqualStrings("openssl@3", entries[0].depends_on[0]);
}

test "collectDeps without --recursive does not walk transitively" {
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    // wget → openssl@3 → ca-certificates. Non-recursive must stop at
    // the direct deps row of wget.
    try db_stub.add("wget", &.{"openssl@3"});
    try db_stub.add("openssl@3", &.{"ca-certificates"});
    try db_stub.add("ca-certificates", &.{});

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        null,
        "wget",
        .{ .recursive = false },
    );
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("wget", entries[0].formula);
}

test "collectDeps --recursive walks the transitive closure once per name" {
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    // wget and openssl@3 both depend on ca-certificates → the dedup
    // must collapse the diamond into a single entry.
    try db_stub.add("wget", &.{ "openssl@3", "ca-certificates" });
    try db_stub.add("openssl@3", &.{"ca-certificates"});
    try db_stub.add("ca-certificates", &.{});

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        null,
        "wget",
        .{ .recursive = true },
    );
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 3), entries.len);

    sortEntriesByName(entries);
    try testing.expectEqualStrings("ca-certificates", entries[0].formula);
    try testing.expectEqual(@as(usize, 0), entries[0].depends_on.len);
    try testing.expectEqualStrings("openssl@3", entries[1].formula);
    try testing.expectEqualStrings("ca-certificates", entries[1].depends_on[0]);
    try testing.expectEqualStrings("wget", entries[2].formula);
}

test "collectDeps: an interrupt stops the transitive walk" {
    // One lookup per node, each possibly a network fetch. Uninterrupted this
    // chain yields all four entries — the closure test above pins that — so a
    // short result here is the walk stopping, not the graph being small.
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    try db_stub.add("a", &.{"b"});
    try db_stub.add("b", &.{"c"});
    try db_stub.add("c", &.{"d"});
    try db_stub.add("d", &.{});

    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    defer signals.armInterruptAfterForTest(0);
    signals.setInterruptedForTest(false);
    signals.armInterruptAfterForTest(2); // fires on the second frontier poll

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        null,
        "a",
        .{ .recursive = true },
    );
    defer freeEntries(testing.allocator, entries);

    // "a" expanded (appending "b"), then the walk stopped: "c"/"d" unreached.
    try testing.expectEqual(@as(usize, 2), entries.len);
}

test "collectDeps --recursive terminates on a cycle" {
    // Real DBs reject cycles, but a corrupt one must still terminate.
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    try db_stub.add("a", &.{"b"});
    try db_stub.add("b", &.{"a"});

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        null,
        "a",
        .{ .recursive = true },
    );
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
}

test "collectDeps falls back to the api when the db misses the root" {
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    var api_stub = StubLookup.init(testing.allocator);
    defer api_stub.deinit();
    try api_stub.add("ffmpeg", &.{ "x264", "lame" });

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        api_stub.lookup(),
        "ffmpeg",
        .{},
    );
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("ffmpeg", entries[0].formula);
    try testing.expectEqual(@as(usize, 2), entries[0].depends_on.len);
}

test "collectDeps prefers the db over the api when both know the name" {
    // The installed row is the truth — that's what users expect even
    // without `--installed`.
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    try db_stub.add("wget", &.{"openssl@3"});
    var api_stub = StubLookup.init(testing.allocator);
    defer api_stub.deinit();
    try api_stub.add("wget", &.{ "openssl@3", "libidn2" });

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        api_stub.lookup(),
        "wget",
        .{},
    );
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries[0].depends_on.len);
    try testing.expectEqualStrings("openssl@3", entries[0].depends_on[0]);
}

test "collectDeps with no api walks only the installed subset" {
    // ffmpeg → {x264, lame}. lame is installed, x264 isn't, no api.
    // The walker must silently drop x264 from the transitive set.
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    try db_stub.add("ffmpeg", &.{ "x264", "lame" });
    try db_stub.add("lame", &.{});

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        null,
        "ffmpeg",
        .{ .recursive = true },
    );
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expect(findEntryByName(entries, "ffmpeg") != null);
    try testing.expect(findEntryByName(entries, "lame") != null);
    try testing.expect(findEntryByName(entries, "x264") == null);
}

test "collectDeps returns an empty slice when the root is unknown" {
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    var api_stub = StubLookup.init(testing.allocator);
    defer api_stub.deinit();

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        api_stub.lookup(),
        "ghost",
        .{ .recursive = true },
    );
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "collectDeps emits a leaf with empty depends_on" {
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    try db_stub.add("leaf", &.{});

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        null,
        "leaf",
        .{},
    );
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("leaf", entries[0].formula);
    try testing.expectEqual(@as(usize, 0), entries[0].depends_on.len);
}

test "encodeJson emits an empty array for no entries" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeJson(&aw.writer, &.{});
    try testing.expectEqualStrings("[]\n", aw.written());
}

test "encodeJson emits a single-entry array for a non-recursive walk" {
    const deps = [_][]const u8{"openssl@3"};
    const entries = [_]Entry{
        .{ .formula = "wget", .depends_on = @constCast(deps[0..]) },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeJson(&aw.writer, &entries);
    try testing.expectEqualStrings(
        "[{\"formula\":\"wget\",\"depends_on\":[\"openssl@3\"]}]\n",
        aw.written(),
    );
}

test "encodeJson preserves entry order for a transitive walk" {
    const wget_deps = [_][]const u8{"openssl@3"};
    const ossl_deps = [_][]const u8{"ca-certificates"};
    const ca_deps = [_][]const u8{};
    const entries = [_]Entry{
        .{ .formula = "wget", .depends_on = @constCast(wget_deps[0..]) },
        .{ .formula = "openssl@3", .depends_on = @constCast(ossl_deps[0..]) },
        .{ .formula = "ca-certificates", .depends_on = @constCast(ca_deps[0..]) },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeJson(&aw.writer, &entries);
    try testing.expectEqualStrings(
        "[" ++
            "{\"formula\":\"wget\",\"depends_on\":[\"openssl@3\"]}," ++
            "{\"formula\":\"openssl@3\",\"depends_on\":[\"ca-certificates\"]}," ++
            "{\"formula\":\"ca-certificates\",\"depends_on\":[]}" ++
            "]\n",
        aw.written(),
    );
}

test "encodeJson escapes special characters in formula and dep names" {
    // Real names won't carry these, but tap-prefixed names and upstream
    // metadata can — so the encoder must escape unconditionally.
    const deps = [_][]const u8{ "back\\slash", "with\nnewline" };
    const entries = [_]Entry{
        .{ .formula = "tap\"name", .depends_on = @constCast(deps[0..]) },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeJson(&aw.writer, &entries);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        std.mem.trimEnd(u8, aw.written(), "\n"),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "tap\"name",
        parsed.value.array.items[0].object.get("formula").?.string,
    );
}

test "encodeHuman emits a not-found line for an unresolved root" {
    // Root resolved neither locally nor upstream → distinct from the
    // "resolved but no deps" path covered below.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeHuman(&aw.writer, "ghost", &.{}, false);
    try testing.expectEqualStrings("ghost: not found.\n", aw.written());
}

test "encodeHuman emits a no-deps line when the root resolves with empty deps" {
    // Real example: `mt deps go` — go is a known formula with zero
    // direct deps. Output must say so explicitly, otherwise the bare
    // name line reads like an unrelated truncation.
    const empty = [_][]const u8{};
    const entries = [_]Entry{
        .{ .formula = "go", .depends_on = @constCast(empty[0..]) },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeHuman(&aw.writer, "go", &entries, false);
    try testing.expectEqualStrings("go has no dependencies.\n", aw.written());
}

test "encodeHuman emits no-deps line in recursive mode too" {
    const empty = [_][]const u8{};
    const entries = [_]Entry{
        .{ .formula = "go", .depends_on = @constCast(empty[0..]) },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeHuman(&aw.writer, "go", &entries, true);
    try testing.expectEqualStrings("go has no dependencies.\n", aw.written());
}

test "encodeHuman prints the root then its direct deps indented" {
    const deps = [_][]const u8{ "openssl@3", "libidn2" };
    const entries = [_]Entry{
        .{ .formula = "wget", .depends_on = @constCast(deps[0..]) },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeHuman(&aw.writer, "wget", &entries, false);
    try testing.expectEqualStrings(
        "wget\n  openssl@3\n  libidn2\n",
        aw.written(),
    );
}

test "encodeHuman recursive walk renders an indented tree" {
    const wget_deps = [_][]const u8{"openssl@3"};
    const ossl_deps = [_][]const u8{"ca-certificates"};
    const ca_deps = [_][]const u8{};
    const entries = [_]Entry{
        .{ .formula = "wget", .depends_on = @constCast(wget_deps[0..]) },
        .{ .formula = "openssl@3", .depends_on = @constCast(ossl_deps[0..]) },
        .{ .formula = "ca-certificates", .depends_on = @constCast(ca_deps[0..]) },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeHuman(&aw.writer, "wget", &entries, true);
    try testing.expectEqualStrings(
        "wget\n  openssl@3\n    ca-certificates\n",
        aw.written(),
    );
}

test "encodeHuman recursive marks an unresolved dep as missing" {
    // `x264` is referenced by ffmpeg but not in the entries map →
    // `--installed -r` should still show the gap so users know that
    // branch wasn't walked.
    const ffmpeg_deps = [_][]const u8{ "x264", "lame" };
    const lame_deps = [_][]const u8{};
    const entries = [_]Entry{
        .{ .formula = "ffmpeg", .depends_on = @constCast(ffmpeg_deps[0..]) },
        .{ .formula = "lame", .depends_on = @constCast(lame_deps[0..]) },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeHuman(&aw.writer, "ffmpeg", &entries, true);
    try testing.expectEqualStrings(
        "ffmpeg\n  x264 (not installed)\n  lame\n",
        aw.written(),
    );
}

test "collectDeps recursive blends DB hits with API fallback for transitive deps" {
    // Diamond where the root is installed (DB hit) but a transitive
    // dep is not — the walker must fall through to the API and keep
    // walking. Mirrors the real flow when `mt deps ffmpeg` lands on a
    // box where ffmpeg is installed but x264 isn't yet.
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    try db_stub.add("ffmpeg", &.{"x264"});

    var api_stub = StubLookup.init(testing.allocator);
    defer api_stub.deinit();
    try api_stub.add("x264", &.{"nasm"});
    try api_stub.add("nasm", &.{});

    const entries = try collectDeps(
        testing.allocator,
        db_stub.lookup(),
        api_stub.lookup(),
        "ffmpeg",
        .{ .recursive = true },
    );
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expect(findEntryByName(entries, "ffmpeg") != null);
    try testing.expect(findEntryByName(entries, "x264") != null);
    try testing.expect(findEntryByName(entries, "nasm") != null);
}

test "collectDeps surfaces allocator failure cleanly" {
    // Touches the OOM branch in `appendEntry` so an exhausted allocator
    // propagates as `error.OutOfMemory` rather than silently emitting a
    // partial result. The failing_allocator allows zero allocations.
    var db_stub = StubLookup.init(testing.allocator);
    defer db_stub.deinit();
    try db_stub.add("wget", &.{"openssl@3"});

    const fa = testing.failing_allocator;
    const got = collectDeps(fa, db_stub.lookup(), null, "wget", .{});
    try testing.expectError(error.OutOfMemory, got);
}

test "encodeHuman recursive stops re-expanding on a cycle" {
    // `a` depends on `b`, `b` depends on `a`. The walker already
    // dedups, but the renderer must also resist re-recursing.
    const a_deps = [_][]const u8{"b"};
    const b_deps = [_][]const u8{"a"};
    const entries = [_]Entry{
        .{ .formula = "a", .depends_on = @constCast(a_deps[0..]) },
        .{ .formula = "b", .depends_on = @constCast(b_deps[0..]) },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeHuman(&aw.writer, "a", &entries, true);
    // `a` at depth 0, `b` at depth 1; the back-edge to `a` is rendered
    // as a leaf so the tree stays finite.
    try testing.expectEqualStrings("a\n  b\n    a\n", aw.written());
}
