//! malt — search command
//! Search formulas and casks.

const std = @import("std");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const color = @import("../ui/color.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const help = @import("help.zig");

/// Results for a single kind (formula or cask) of a search query.
///
/// `index` and `matches` are separately owned because `matches` elements
/// are slices *into* `index` — freeing `index` invalidates them. Callers
/// must deinit via `deinit` to release both in the right order.
const KindResults = struct {
    exact: bool = false,
    index: ?[]const u8 = null,
    matches: []const []const u8 = &.{},

    fn deinit(self: *KindResults, allocator: std.mem.Allocator) void {
        if (self.matches.len != 0) allocator.free(self.matches);
        if (self.index) |b| allocator.free(b);
    }
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "search")) return;

    // Parse flags and positional args
    var search_formula = false;
    var search_cask = false;
    var query: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            search_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            search_cask = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (query == null) query = arg;
        }
    }

    const search_query = query orelse {
        output.err("Usage: mt search <query>", .{});
        return error.Aborted;
    };

    // If neither specified, search both
    if (!search_formula and !search_cask) {
        search_formula = true;
        search_cask = true;
    }

    // --json is consumed by the global arg parser; check output module
    const json_mode = output.isJson();

    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to determine cache directory", .{});
        return error.Aborted;
    };
    defer allocator.free(cache_dir);

    // When both kinds are requested we dispatch the cask work to a
    // worker thread so the two independent JSON index downloads
    // (formula ~29 MiB, cask ~14 MiB) overlap. On a cold cache this
    // roughly halves wall time; on a warm cache the thread is created
    // and joined in under a millisecond so the overhead is noise.
    //
    // `std.http.Client` is not safe to share across threads, so each
    // path owns its own `HttpClient`. The synchronous single-kind
    // paths keep the original one-client shape to avoid pointless
    // thread spawns.
    var formula: KindResults = .{};
    var cask: KindResults = .{};
    defer formula.deinit(allocator);
    defer cask.deinit(allocator);

    if (search_formula and search_cask) {
        // malt's main allocator is an `ArenaAllocator` which is not
        // safe to call concurrently — two threads racing on the same
        // arena can see misaligned returns and corrupted free lists
        // (observed on release builds as "thread panic: incorrect
        // alignment" inside `std.http.Client.Connection.Tls.create`).
        // Wrap it with a mutex-guarded allocator for the parallel
        // section; results flow back to the caller's allocator via
        // `dupe`, so the safe wrapper can go out of scope after join.
        var safe: std.heap.ThreadSafeAllocator = .{ .child_allocator = allocator };
        const shared = safe.allocator();

        var cask_task: KindTask = .{
            .allocator = shared,
            .cache_dir = cache_dir,
            .kind = .cask,
            .query = search_query,
        };
        const worker = std.Thread.spawn(.{}, KindTask.run, .{&cask_task}) catch null;
        formula = runKindIsolated(shared, cache_dir, .formula, search_query);
        if (worker) |w| {
            w.join();
            cask = cask_task.result;
        } else {
            // Spawn failed — fall back to running cask inline. Rare
            // enough (only on thread-creation failure) that the
            // sequential path is fine.
            cask = runKindIsolated(allocator, cache_dir, .cask, search_query);
        }
    } else if (search_formula) {
        formula = runKindIsolated(allocator, cache_dir, .formula, search_query);
    } else if (search_cask) {
        cask = runKindIsolated(allocator, cache_dir, .cask, search_query);
    }

    const stdout = std.fs.File.stdout();
    if (json_mode) {
        try emitJson(allocator, stdout, search_formula, search_cask, formula, cask, search_query);
    } else {
        emitHuman(stdout, formula, cask, search_query);
    }
}

/// Run the exact + substring search for one kind with a locally-owned
/// HTTP client. Errors from the API are swallowed into empty results —
/// `mt search` is best-effort and a transient network failure should
/// not abort the whole command.
fn runKindIsolated(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    kind: api_mod.BrewApi.Kind,
    query: []const u8,
) KindResults {
    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);
    var r: KindResults = .{};
    r.exact = api.exists(query, kind) catch false;
    if (api.fetchNamesIndex(kind)) |idx| {
        r.index = idx;
        r.matches = api_mod.findNameMatches(allocator, idx, query) catch &.{};
    } else |_| {}
    return r;
}

/// Thread entry-point wrapper so `std.Thread.spawn` can call it with a
/// single pointer argument. The result is written back into the struct
/// the caller allocated on its stack, read after `join()`.
const KindTask = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    kind: api_mod.BrewApi.Kind,
    query: []const u8,
    result: KindResults = .{},

    fn run(self: *KindTask) void {
        self.result = runKindIsolated(self.allocator, self.cache_dir, self.kind, self.query);
    }
};

fn emitHuman(
    stdout: std.fs.File,
    formula: KindResults,
    cask: KindResults,
    query: []const u8,
) void {
    writeHuman(stdout, "formula", formula, query);
    writeHuman(stdout, "cask", cask, query);

    const any = formula.exact or cask.exact or
        formula.matches.len != 0 or cask.matches.len != 0;
    if (!any and !output.isQuiet()) {
        output.info("No results found for \"{s}\"", .{query});
    }
}

/// Write substring matches for one kind, with the exact match (if any)
/// pinned to the top and deduped against the substring list. The index
/// may not yet include a brand-new formula the API already serves, so
/// relying on substring membership alone to surface exact matches would
/// under-report on the day of a new release.
fn writeHuman(
    stdout: std.fs.File,
    kind: []const u8,
    r: KindResults,
    query: []const u8,
) void {
    if (r.exact) writeResult(stdout, query, kind);
    for (r.matches) |m| {
        if (r.exact and std.mem.eql(u8, m, query)) continue;
        writeResult(stdout, m, kind);
    }
}

fn emitJson(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    search_formula: bool,
    search_cask: bool,
    formula: KindResults,
    cask: KindResults,
    query: []const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{");
    if (search_formula) {
        try w.writeAll("\"formulae\":[");
        try writeJson(w, "name", formula, query);
        try w.writeAll("]");
    }
    if (search_cask) {
        if (search_formula) try w.writeAll(",");
        try w.writeAll("\"casks\":[");
        try writeJson(w, "token", cask, query);
        try w.writeAll("]");
    }
    try w.writeAll("}\n");
    stdout.writeAll(buf.items) catch {};
}

fn writeJson(w: anytype, field: []const u8, r: KindResults, query: []const u8) !void {
    var first = true;
    if (r.exact) {
        try writeJsonObj(w, field, query);
        first = false;
    }
    for (r.matches) |m| {
        if (r.exact and std.mem.eql(u8, m, query)) continue;
        if (!first) try w.writeAll(",");
        try writeJsonObj(w, field, m);
        first = false;
    }
}

fn writeJsonObj(w: anytype, field: []const u8, value: []const u8) !void {
    try w.writeAll("{\"");
    try w.writeAll(field);
    try w.writeAll("\":");
    try output.jsonStr(w, value);
    try w.writeAll("}");
}

/// Write a single search result with the same ▸ prefix style used by `list`.
fn writeResult(stdout: std.fs.File, name: []const u8, kind: []const u8) void {
    const use_color = color.isColorEnabled();
    if (use_color) stdout.writeAll(color.Style.cyan.code()) catch {};
    stdout.writeAll("  \xe2\x96\xb8 ") catch {};
    if (use_color) stdout.writeAll(color.Style.reset.code()) catch {};
    stdout.writeAll(name) catch {};
    if (use_color) stdout.writeAll(color.Style.dim.code()) catch {};
    stdout.writeAll(" (") catch {};
    stdout.writeAll(kind) catch {};
    stdout.writeAll(")") catch {};
    if (use_color) stdout.writeAll(color.Style.reset.code()) catch {};
    stdout.writeAll("\n") catch {};
}
