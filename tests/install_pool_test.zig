//! Integration tests for `cli/install/download.zig::installPoolWorker`.
//!
//! The pool is what `cli/install.zig::execute` spawns once per install
//! run: a bounded set of workers that each pull the next job index
//! atomically and call `installKegFromBottle` against the per-job
//! formula. These tests pin the worker's draining contract end-to-end
//! against a real on-disk prefix with a pre-seeded warm store, so the
//! pipeline runs the same store + cellar code paths production hits.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const formula_mod = malt.formula;
const sqlite = malt.sqlite;
const schema = malt.schema;

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_installpool_{d}_{s}",
        .{ test_io.nanoTimestamp(std.Options.debug_io), suffix },
        0,
    );
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    inline for (.{ "store", "Cellar" }) |sub| {
        const dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, sub });
        defer testing.allocator.free(dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, dir);
    }
    return path;
}

fn seedWarmStore(
    prefix: []const u8,
    sha: []const u8,
    name: []const u8,
    version: []const u8,
) !void {
    const inner = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/store/{s}/{s}/{s}",
        .{ prefix, sha, name, version },
    );
    defer testing.allocator.free(inner);
    try test_io.cwd().createDirPath(std.Options.debug_io, inner);
    const readme = try std.fmt.allocPrint(testing.allocator, "{s}/README", .{inner});
    defer testing.allocator.free(readme);
    const f = try test_io.cwd().createFile(std.Options.debug_io, readme, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, "warm-pool integration probe\n");
}

fn anyPlatformFormulaJson(
    arena: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    sha: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{{
        \\  "name": "{s}",
        \\  "full_name": "{s}",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "versions": {{"stable": "{s}"}},
        \\  "revision": 0,
        \\  "dependencies": [],
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "oldnames": [],
        \\  "bottle": {{"stable": {{"files": {{"all": {{"cellar": ":any", "url": "https://ghcr.io/v2/homebrew/core/{s}/blobs/sha256:{s}", "sha256": "{s}"}}}}}}}}
        \\}}
    , .{ name, name, version, name, sha, sha });
}

fn makeJob(name: []const u8, version: []const u8, sha: []const u8) malt.install.DownloadJob {
    return .{
        .name = name,
        .version_str = version,
        .sha256 = sha,
        .bottle_url = "",
        .is_dep = false,
        .keg_only = false,
        .post_install_defined = false,
        .formula_json = "",
        .cellar_type = ":any",
        .label_width = 0,
        .line_index = 0,
        .multi = null,
        .bar = null,
        .store_sha256 = "",
        .succeeded = false,
    };
}

test "installPoolWorker drains every job against a warm store and stamps each result" {
    const prefix = try setupPrefix("drain");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    // Two jobs, both warm. The atomic-index loop must hand both out and
    // stop cleanly at the end — no off-by-one, no double-processing.
    const sha_a = "aaaa" ** 16;
    const sha_b = "bbbb" ** 16;
    try seedWarmStore(prefix, sha_a, "alpha", "1.0");
    try seedWarmStore(prefix, sha_b, "beta", "2.0");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json_a = try anyPlatformFormulaJson(arena.allocator(), "alpha", "1.0", sha_a);
    const json_b = try anyPlatformFormulaJson(arena.allocator(), "beta", "2.0", sha_b);

    var cache = malt.deps.FormulaCache.init(testing.allocator);
    defer cache.deinit();
    _ = try cache.getOrParse("alpha", json_a);
    _ = try cache.getOrParse("beta", json_b);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var http_pool = try malt.client.HttpClientPool.init(ctx.io, ctx.environ, testing.allocator, 1);
    defer http_pool.deinit();
    // ghcr/http are required by the worker signature but the warm-store
    // fast path inside `installKegFromBottle` short-circuits before any
    // network call, so the local HttpClient never opens a connection.
    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, testing.allocator);
    defer http.deinit();
    var ghcr = malt.ghcr.GhcrClient.init(ctx.io, testing.allocator, &http);
    defer ghcr.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var store = malt.store.Store.init(ctx.io, testing.allocator, &db, prefix);

    var jobs = [_]malt.install.DownloadJob{
        makeJob("alpha", "1.0", sha_a),
        makeJob("beta", "2.0", sha_b),
    };
    var results: [2]malt.install.MaterializeResult = .{
        .{ .ok = false, .err = null },
        .{ .ok = false, .err = null },
    };

    var pool: malt.install.InstallPool = .{
        .ctx = &ctx,
        .next_idx = std.atomic.Value(usize).init(0),
        .jobs = &jobs,
        .prefix = prefix,
        .ghcr = &ghcr,
        .http_pool = &http_pool,
        .store = &store,
        .cache = &cache,
        .results = &results,
    };

    malt.install.installPoolWorker(&pool);

    // Every slot must have been touched — atomic index handed each one
    // out exactly once; success means warm path landed both kegs.
    for (results, 0..) |r, i| {
        try testing.expect(r.ok);
        try testing.expect(r.err == null);
        try testing.expect(r.keg_path_len > 0);
        try testing.expect(jobs[i].succeeded);
    }

    // Keg paths match the canonical Cellar/<name>/<version> shape so the
    // serial link phase downstream has a valid path to hand to the linker.
    const path_a = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/alpha/1.0", .{prefix});
    defer testing.allocator.free(path_a);
    const path_b = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/beta/2.0", .{prefix});
    defer testing.allocator.free(path_b);
    try testing.expectEqualStrings(path_a, results[0].kegPath());
    try testing.expectEqualStrings(path_b, results[1].kegPath());

    // Cellar/<name>/<version>/README — cellar materialise actually wrote
    // the keg, not just stamped the result struct.
    const readme_a = try std.fmt.allocPrint(testing.allocator, "{s}/README", .{path_a});
    defer testing.allocator.free(readme_a);
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, readme_a, .{});
}

test "installPoolWorker drains a 3-job pool concurrently across two workers" {
    const prefix = try setupPrefix("concurrent");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    // Three warm jobs, two workers: each worker must skip past slots
    // already claimed by its sibling without re-processing them. The
    // atomic counter handles the handoff; a regression here would
    // double-materialise or skip a slot.
    const sha_a = "1111" ** 16;
    const sha_b = "2222" ** 16;
    const sha_c = "3333" ** 16;
    try seedWarmStore(prefix, sha_a, "one", "1.0");
    try seedWarmStore(prefix, sha_b, "two", "2.0");
    try seedWarmStore(prefix, sha_c, "three", "3.0");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json_a = try anyPlatformFormulaJson(arena.allocator(), "one", "1.0", sha_a);
    const json_b = try anyPlatformFormulaJson(arena.allocator(), "two", "2.0", sha_b);
    const json_c = try anyPlatformFormulaJson(arena.allocator(), "three", "3.0", sha_c);

    var cache = malt.deps.FormulaCache.init(testing.allocator);
    defer cache.deinit();
    _ = try cache.getOrParse("one", json_a);
    _ = try cache.getOrParse("two", json_b);
    _ = try cache.getOrParse("three", json_c);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    // Two-slot HTTP pool so the two workers can both acquire without
    // either one blocking on the warm-store fast path.
    var http_pool = try malt.client.HttpClientPool.init(ctx.io, ctx.environ, testing.allocator, 2);
    defer http_pool.deinit();
    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, testing.allocator);
    defer http.deinit();
    var ghcr = malt.ghcr.GhcrClient.init(ctx.io, testing.allocator, &http);
    defer ghcr.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var store = malt.store.Store.init(ctx.io, testing.allocator, &db, prefix);

    var jobs = [_]malt.install.DownloadJob{
        makeJob("one", "1.0", sha_a),
        makeJob("two", "2.0", sha_b),
        makeJob("three", "3.0", sha_c),
    };
    var results: [3]malt.install.MaterializeResult = .{
        .{ .ok = false, .err = null },
        .{ .ok = false, .err = null },
        .{ .ok = false, .err = null },
    };

    var pool: malt.install.InstallPool = .{
        .ctx = &ctx,
        .next_idx = std.atomic.Value(usize).init(0),
        .jobs = &jobs,
        .prefix = prefix,
        .ghcr = &ghcr,
        .http_pool = &http_pool,
        .store = &store,
        .cache = &cache,
        .results = &results,
    };

    const t1 = try std.Thread.spawn(.{}, malt.install.installPoolWorker, .{&pool});
    const t2 = try std.Thread.spawn(.{}, malt.install.installPoolWorker, .{&pool});
    t1.join();
    t2.join();

    // Atomic index gave each worker a distinct slot; no slot got
    // double-handled (would have re-materialised over an existing dir
    // and surfaced as a CellarError), none got skipped.
    for (results, 0..) |r, i| {
        try testing.expect(r.ok);
        try testing.expect(r.err == null);
        try testing.expect(r.keg_path_len > 0);
        try testing.expect(jobs[i].succeeded);
    }

    // Final index sat past the last slot — confirms no extra increments
    // leaked from a re-entry.
    try testing.expectEqual(@as(usize, 5), pool.next_idx.load(.acquire));
}

// The materialise-failure → CloneFailed mapping is covered end-to-end by
// `scripts/regressions/install_zig_clonefail_gh85.sh`, which runs a real
// install against pre-planted stale Cellar dirs and greps the install
// log for the `Failed to materialize ... CloneFailed` surface. A purely
// hermetic CellarFailed is hard to provoke without faking filesystem
// permissions — the regression script is the source of truth here.

test "installPoolWorker leaves the result untouched and marks job not-succeeded on a missing-formula entry" {
    const prefix = try setupPrefix("nocache");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var cache = malt.deps.FormulaCache.init(testing.allocator);
    defer cache.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var http_pool = try malt.client.HttpClientPool.init(ctx.io, ctx.environ, testing.allocator, 1);
    defer http_pool.deinit();
    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, testing.allocator);
    defer http.deinit();
    var ghcr = malt.ghcr.GhcrClient.init(ctx.io, testing.allocator, &http);
    defer ghcr.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var store = malt.store.Store.init(ctx.io, testing.allocator, &db, prefix);

    var jobs = [_]malt.install.DownloadJob{makeJob("ghost", "0.1", "deadbeef" ** 8)};
    var results: [1]malt.install.MaterializeResult = .{.{ .ok = false, .err = null }};

    var pool: malt.install.InstallPool = .{
        .ctx = &ctx,
        .next_idx = std.atomic.Value(usize).init(0),
        .jobs = &jobs,
        .prefix = prefix,
        .ghcr = &ghcr,
        .http_pool = &http_pool,
        .store = &store,
        .cache = &cache,
        .results = &results,
    };

    malt.install.installPoolWorker(&pool);

    // collectFormulaJobs is the only legitimate path into the pool and
    // always pre-caches the formula; a miss here is a programming error.
    // The worker must surface it as a not-succeeded job so the serial
    // link phase routes the package into the "Download failed" branch
    // rather than dereferencing a stale result.
    try testing.expect(!results[0].ok);
    try testing.expect(results[0].err == null);
    try testing.expect(!jobs[0].succeeded);
}
