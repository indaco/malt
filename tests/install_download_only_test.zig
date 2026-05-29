//! malt — `mt install --download-only` integration tests.
//!
//! Pins the new exit point in the install pipeline:
//!   - bottle bytes land in `<prefix>/store/<sha>/...`
//!   - Cellar and the `kegs` table stay untouched
//!   - `--ndjson` emits `download_started` / `download_complete` events
//!   - argv refuses the ambiguous `--only-dependencies` combo
//!   - human stdout prints the resolved bottle paths
//!
//! Bottle bytes are seeded into the store before `install.execute` runs
//! so the test stays offline — the warm-store branch inside
//! `installKegFromBottle` is the production code-path the download-only
//! exit point reuses for the "already cached" case.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const install = malt.install;
const install_record = malt.install_record;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_install_dlonly_{d}_{s}",
        .{ test_io.nanoTimestamp(std.Options.debug_io), suffix },
        0,
    );
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    inline for (.{ "store", "Cellar", "cache", "db" }) |sub| {
        const dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, sub });
        defer testing.allocator.free(dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, dir);
    }
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

fn seedFormulaCache(prefix: []const u8, name: []const u8, json: []const u8) !void {
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{prefix});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/formula_{s}.json", .{ cache_api, name });
    defer testing.allocator.free(path);
    const f = try test_io.cwd().createFile(std.Options.debug_io, path, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, json);
}

// Seed `<prefix>/store/<sha>/...` so `installKegFromBottle` takes the warm
// path and never reaches the network. The same layout an offline-cached
// run would produce.
fn seedStoreBottle(prefix: []const u8, sha: []const u8, name: []const u8, version: []const u8) !void {
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
    try f.writeStreamingAll(std.Options.debug_io, "download-only fixture\n");
}

fn warmFormulaJson(allocator: std.mem.Allocator, name: []const u8, sha: []const u8) ![]const u8 {
    // `"all"` platform key wins on every host arch — keeps these tests
    // arch-independent and avoids encoding the macOS codename list twice.
    return std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "name": "{s}",
        \\  "full_name": "{s}",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "versions": {{"stable": "1.0"}},
        \\  "revision": 0,
        \\  "dependencies": [],
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "oldnames": [],
        \\  "bottle": {{"stable": {{"files": {{"all": {{"cellar": ":any", "url": "https://ghcr.io/v2/homebrew/core/{s}/blobs/sha256:{s}", "sha256": "{s}"}}}}}}}}
        \\}}
    ,
        .{ name, name, name, sha, sha },
    );
}

fn kegRowCount(prefix: []const u8) !i64 {
    const db_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/db/malt.db",
        .{prefix},
        0,
    );
    defer testing.allocator.free(db_path);
    var db = try malt.sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT COUNT(*) FROM kegs;");
    defer stmt.finalize();
    _ = try stmt.step();
    return stmt.columnInt(0);
}

fn pathExists(path: []const u8) bool {
    test_io.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

test "execute refuses --download-only combined with --only-dependencies" {
    // The two flags are semantically ambiguous: one says "don't touch the
    // requested package", the other says "don't materialise anything".
    // Document the refusal up front rather than silently picking a winner.
    // The check must run before any infra setup so the test does not need
    // to seed a cache or stub the network.
    const prefix = try setupPrefix("ambig");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(
        error.Aborted,
        install.execute(
            &ctx,
            arena.allocator(),
            &.{ "--download-only", "--only-dependencies", "alpha" },
        ),
    );
}

test "--download-only --ndjson emits download_started + download_complete around the fetch" {
    // Pin the event shape new consumers (CI pipelines, Docker layer
    // builders) get from the warm-cache path. The events must bracket
    // every per-job fetch — no fan-out, no dropped events, and
    // download_complete carries "ok" for the warm-store skip.
    const prefix = try setupPrefix("nd");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const sha = "cd" ** 32;
    try seedStoreBottle(prefix, sha, "ndpkg", "1.0");
    var arena_json = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_json.deinit();
    const json = try warmFormulaJson(arena_json.allocator(), "ndpkg", sha);
    try seedFormulaCache(prefix, "ndpkg", json);

    const prior = malt.output.isNdjson();
    malt.output.setNdjson(true);
    defer malt.output.setNdjson(prior);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &captured);
    defer malt.output.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try install.execute(&ctx, arena.allocator(), &.{ "--download-only", "--quiet", "ndpkg" });

    // Exactly one started + one complete for the single requested package.
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, captured.items, "\"event\":\"download_started\",\"name\":\"ndpkg\""),
    );
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, captured.items, "\"event\":\"download_complete\",\"name\":\"ndpkg\",\"status\":\"ok\""),
    );
}

test "--download-only prints the resolved bottle path under the prefix store" {
    // The visible signal a user gets when warming a cache: the absolute
    // `<prefix>/store/<sha>` path of each downloaded bottle. Without this
    // line the command would look like a silent no-op against the user's
    // expectation of "fetched X to disk".
    const prefix = try setupPrefix("paths");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const sha = "ef" ** 32;
    try seedStoreBottle(prefix, sha, "pathpkg", "1.0");
    var arena_json = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_json.deinit();
    const json = try warmFormulaJson(arena_json.allocator(), "pathpkg", sha);
    try seedFormulaCache(prefix, "pathpkg", json);

    // Quiet is process-global and other tests leave it set; reset so the
    // success line reaches our capture.
    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try install.execute(&ctx, arena.allocator(), &.{ "--download-only", "pathpkg" });

    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "pathpkg 1.0 downloaded to {s}/store/{s}",
        .{ prefix, sha },
    );
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.indexOf(u8, captured.items, expected) != null);
}

test "--download-only --dry-run prints the plan and never touches the store" {
    // dry-run takes precedence — the plan header still fires, no
    // download_started/complete events are emitted, and the bottle path
    // line is not printed. Locks in the precedence so a future refactor
    // can't accidentally make --download-only swallow --dry-run.
    const prefix = try setupPrefix("dr");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const sha = "aa" ** 32;
    var arena_json = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_json.deinit();
    const json = try warmFormulaJson(arena_json.allocator(), "dr", sha);
    try seedFormulaCache(prefix, "dr", json);

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try install.execute(&ctx, arena.allocator(), &.{ "--download-only", "--dry-run", "dr" });

    try testing.expect(std.mem.indexOf(u8, captured.items, "would install") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "downloaded to") == null);

    // Nothing seeded the store, and dry-run skipped the fetch, so the
    // SHA directory must still be absent.
    const store_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}", .{ prefix, sha });
    defer testing.allocator.free(store_dir);
    try testing.expect(!pathExists(store_dir));
}

test "--download-only with multiple packages prints one resolved path per package" {
    // Two leaf formulas exercise the loop in the download-only short-circuit
    // and pin the per-package emit order: success lines must appear for
    // every requested name, not just the first.
    const prefix = try setupPrefix("multi");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const sha_a = "11" ** 32;
    const sha_b = "22" ** 32;
    try seedStoreBottle(prefix, sha_a, "alpha", "1.0");
    try seedStoreBottle(prefix, sha_b, "beta", "1.0");
    var arena_json = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_json.deinit();
    const a_json = try warmFormulaJson(arena_json.allocator(), "alpha", sha_a);
    const b_json = try warmFormulaJson(arena_json.allocator(), "beta", sha_b);
    try seedFormulaCache(prefix, "alpha", a_json);
    try seedFormulaCache(prefix, "beta", b_json);

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try install.execute(&ctx, arena.allocator(), &.{ "--download-only", "alpha", "beta" });

    const want_a = try std.fmt.allocPrint(testing.allocator, "alpha 1.0 downloaded to {s}/store/{s}", .{ prefix, sha_a });
    defer testing.allocator.free(want_a);
    const want_b = try std.fmt.allocPrint(testing.allocator, "beta 1.0 downloaded to {s}/store/{s}", .{ prefix, sha_b });
    defer testing.allocator.free(want_b);
    try testing.expect(std.mem.indexOf(u8, captured.items, want_a) != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, want_b) != null);
}

test "--download-only with one cached + one 404 package exits PartialFailure" {
    // Mixed --download-only: alpha is cache-warm + store-seeded so the
    // pool short-circuits to success; zzbad is .404 so the dispatch loop
    // counts the miss. Pre-fix the download-only early return ignored
    // `failed_count` and exited 0 with a printed "Cask 'zzbad' not found"
    // — the very antipattern T-049 was supposed to close.
    const prefix = try setupPrefix("dlmix");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const sha_a = "33" ** 32;
    try seedStoreBottle(prefix, sha_a, "alpha", "1.0");
    var arena_json = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_json.deinit();
    const a_json = try warmFormulaJson(arena_json.allocator(), "alpha", sha_a);
    try seedFormulaCache(prefix, "alpha", a_json);

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{prefix});
    defer testing.allocator.free(cache_api);
    inline for (.{ "formula_zzbad.404", "cask_zzbad.404" }) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ cache_api, name });
        defer testing.allocator.free(p);
        const f = try test_io.createFileAbsolute(std.Options.debug_io, p, .{ .truncate = true });
        f.close(std.Options.debug_io);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(
        install_record.InstallError.PartialFailure,
        install.execute(&ctx, arena.allocator(), &.{ "--download-only", "--quiet", "alpha", "zzbad" }),
    );
}

test "--download-only --cask is plumbed into the cask path and threads the flag" {
    // The argv parser must accept `--download-only` alongside `--cask`,
    // and the per-package dispatcher must route the request through
    // `installCask` (which honours the flag). Anchor via the cached-API
    // already-installed branch: a seeded `casks` row would normally
    // trigger the "already installed" short-circuit on the regular path,
    // but `--download-only` deliberately bypasses that gate so warmed
    // caches can be refreshed ahead of an upgrade. We assert the bypass
    // by capturing that no "already installed" line is printed even
    // though the row exists — and the run still terminates with a
    // cask-fetch error (because there's no network in this test, the
    // cache lookup for the cask JSON misses).
    const prefix_z: [:0]const u8 = "/tmp/mc_dl";
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // Seed a `casks` row for the same token so the normal `isInstalled`
    // gate would short-circuit. `--download-only` must skip the gate.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix_z});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
    defer testing.allocator.free(db_path);
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        var stmt = try db.prepare(
            \\INSERT INTO casks (token, name, version, url, sha256, app_path)
            \\VALUES (?, ?, ?, ?, ?, ?);
        );
        defer stmt.finalize();
        try stmt.bindText(1, "ghost-cask");
        try stmt.bindText(2, "ghost-cask");
        try stmt.bindText(3, "1.0");
        try stmt.bindText(4, "https://example.test/ghost.dmg");
        try stmt.bindText(5, "0" ** 64);
        try stmt.bindText(6, "/Applications/Ghost.app");
        _ = try stmt.step();
    }

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    // `--cask` + an unresolvable token → `fetchCask` errors. The
    // important assertion is that we DIDN'T short-circuit on the seeded
    // already-installed row — i.e., `--download-only` rerouted the flow
    // through the download path. The cask-dispatch failure now counts
    // into `failed_count`, so the single-package run exits with
    // PartialFailure.
    try testing.expectError(
        install_record.InstallError.PartialFailure,
        install.execute(&ctx, arena.allocator(), &.{ "--download-only", "--cask", "ghost-cask" }),
    );

    try testing.expect(std.mem.indexOf(u8, captured.items, "ghost-cask is already installed") == null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "Cask 'ghost-cask' not found") != null);
}

test "--download-only on tap formula with warm tap cache prints path + skips Cellar" {
    // Pin the new tap exit point: when `<prefix>/cache/Tap/<sha>.<ext>`
    // already holds the archive, `materializeRubyFormula` must short-
    // circuit before the HTTP fetch, print the resolved cache path, and
    // leave the Cellar + kegs untouched. The URL is deliberately a
    // non-resolvable host so a regression that drops the cache-hit
    // branch would surface as a network failure instead of a silent
    // pass.
    const prefix = try setupPrefix("tap_warm");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const sha = "ee" ** 32;

    var cache_parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_parent = try std.fmt.bufPrint(&cache_parent_buf, "{s}/cache/Tap", .{prefix});
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_parent);

    var cache_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try malt.tap_cache.cachePath(&cache_path_buf, prefix, sha, ".tar.gz");
    {
        const f = try test_io.cwd().createFile(std.Options.debug_io, cache_path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "warm-tap-archive-fixture\n");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();

    const db_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/db/malt.db",
        .{prefix},
        0,
    );
    defer testing.allocator.free(db_path);
    var db = try malt.sqlite.Database.open(db_path);
    defer db.close();
    try malt.schema.initSchema(&db);

    var linker = malt.linker.Linker.init(ctx.io, allocator, &db, prefix);

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    const resolved: malt.install_local.ResolvedRubyFormula = .{
        .name = "tappkg",
        .full_name = "user/repo/tappkg",
        .tap_label = "user/repo",
        .version = "1.0",
        .url = "https://malt-tap-test.invalid/tappkg-1.0.tar.gz",
        .sha256 = sha,
    };

    try malt.install_local.materializeRubyFormula(
        &ctx,
        allocator,
        resolved,
        &http,
        &db,
        &linker,
        prefix,
        false, // dry_run
        false, // force
        true, // download_only
        malt.install_sink.terminal,
    );

    const want = try std.fmt.allocPrint(
        testing.allocator,
        "tappkg 1.0 downloaded to {s}",
        .{cache_path},
    );
    defer testing.allocator.free(want);
    try testing.expect(std.mem.indexOf(u8, captured.items, want) != null);

    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/tappkg", .{prefix});
    defer testing.allocator.free(cellar);
    try testing.expect(!pathExists(cellar));

    try testing.expectEqual(@as(i64, 0), try kegRowCount(prefix));
}

test "--download-only --force on tap formula with warm cache is a no-op refresh" {
    // `--force` semantics for a regular install pre-wipe the Cellar
    // dir; for `--download-only` there's no Cellar to wipe, and the
    // cache filename is the SHA so a "force" cannot mean refetch the
    // same bytes. Pin that the combination prints the cache path,
    // leaves the cache file intact, and never touches Cellar or kegs.
    const prefix = try setupPrefix("tap_force");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const sha = "22" ** 32;

    var cache_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = try std.fmt.bufPrint(&cache_dir_buf, "{s}/cache/Tap", .{prefix});
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_dir);

    var cache_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try malt.tap_cache.cachePath(&cache_path_buf, prefix, sha, ".tar.gz");
    {
        const f = try test_io.cwd().createFile(std.Options.debug_io, cache_path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "force-tap-fixture\n");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();

    const db_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/db/malt.db",
        .{prefix},
        0,
    );
    defer testing.allocator.free(db_path);
    var db = try malt.sqlite.Database.open(db_path);
    defer db.close();
    try malt.schema.initSchema(&db);

    var linker = malt.linker.Linker.init(ctx.io, allocator, &db, prefix);

    const resolved: malt.install_local.ResolvedRubyFormula = .{
        .name = "forcetap",
        .full_name = "user/repo/forcetap",
        .tap_label = "user/repo",
        .version = "1.0",
        .url = "https://malt-tap-test.invalid/forcetap-1.0.tar.gz",
        .sha256 = sha,
    };

    try malt.install_local.materializeRubyFormula(
        &ctx,
        allocator,
        resolved,
        &http,
        &db,
        &linker,
        prefix,
        false, // dry_run
        true, // force
        true, // download_only
        malt.install_sink.terminal,
    );

    // Cache file untouched.
    try test_io.accessAbsolute(std.Options.debug_io, cache_path, .{});

    // Cellar untouched.
    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/forcetap", .{prefix});
    defer testing.allocator.free(cellar);
    try testing.expect(!pathExists(cellar));

    try testing.expectEqual(@as(i64, 0), try kegRowCount(prefix));
}

test "--download-only --ndjson on tap formula emits download_started + complete around fetch" {
    // Pin the ndjson event vocabulary for the tap path so CI pipelines
    // can rely on the same `download_started` / `download_complete`
    // bracket they see on the bottle + cask paths. Warm-cache fixture
    // keeps the test offline; the events fire either way.
    const prefix = try setupPrefix("tap_nd");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const sha = "11" ** 32;

    var cache_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = try std.fmt.bufPrint(&cache_dir_buf, "{s}/cache/Tap", .{prefix});
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_dir);

    var cache_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try malt.tap_cache.cachePath(&cache_path_buf, prefix, sha, ".tar.gz");
    {
        const f = try test_io.cwd().createFile(std.Options.debug_io, cache_path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "ndjson-tap-fixture\n");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();

    const db_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/db/malt.db",
        .{prefix},
        0,
    );
    defer testing.allocator.free(db_path);
    var db = try malt.sqlite.Database.open(db_path);
    defer db.close();
    try malt.schema.initSchema(&db);

    var linker = malt.linker.Linker.init(ctx.io, allocator, &db, prefix);

    const prior_nd = malt.output.isNdjson();
    malt.output.setNdjson(true);
    defer malt.output.setNdjson(prior_nd);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &captured);
    defer malt.output.endStdoutCapture();

    const resolved: malt.install_local.ResolvedRubyFormula = .{
        .name = "ndtap",
        .full_name = "user/repo/ndtap",
        .tap_label = "user/repo",
        .version = "1.0",
        .url = "https://malt-tap-test.invalid/ndtap-1.0.tar.gz",
        .sha256 = sha,
    };

    try malt.install_local.materializeRubyFormula(
        &ctx,
        allocator,
        resolved,
        &http,
        &db,
        &linker,
        prefix,
        false, // dry_run
        false, // force
        true, // download_only
        malt.install_sink.terminal,
    );

    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, captured.items, "\"event\":\"download_started\",\"name\":\"ndtap\""),
    );
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, captured.items, "\"event\":\"download_complete\",\"name\":\"ndtap\",\"status\":\"ok\""),
    );
}

test "--download-only populates the store and skips Cellar + kegs" {
    // Pre-seed the store so the warm-path branch inside the install pool
    // skips the network entirely. The new exit point must short-circuit
    // before `materializeWithCellar`, leaving Cellar empty and the kegs
    // table at zero rows — that is the property a follow-up real install
    // can rely on when consuming the warmed bytes.
    const prefix = try setupPrefix("warm");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const sha = "ab" ** 32; // 64-char hex placeholder
    try seedStoreBottle(prefix, sha, "warmpkg", "1.0");
    var arena_json = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_json.deinit();
    const json = try warmFormulaJson(arena_json.allocator(), "warmpkg", sha);
    try seedFormulaCache(prefix, "warmpkg", json);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try install.execute(&ctx, arena.allocator(), &.{ "--download-only", "--quiet", "warmpkg" });

    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/warmpkg/1.0", .{prefix});
    defer testing.allocator.free(cellar);
    try testing.expect(!pathExists(cellar));

    const store_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}", .{ prefix, sha });
    defer testing.allocator.free(store_dir);
    try testing.expect(pathExists(store_dir));

    try testing.expectEqual(@as(i64, 0), try kegRowCount(prefix));
}
