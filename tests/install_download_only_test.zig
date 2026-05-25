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
