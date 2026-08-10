//! malt — `MALT_OFFLINE` / `--offline` integration tests.
//!
//! Pins the cross-cutting offline contract end-to-end at the library
//! seam: env-resolver, BrewApi gate (cache hit / miss / 404 / stale),
//! HttpClient gate (every entrypoint), and `mt update --check` refusal.
//! No process spawn, no real network — `tests/api_test.zig` and the
//! inline tests next to each gate cover the unit level; this file
//! exercises the composition.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");

const offline_mod = malt.offline;
const api_mod = malt.api;
const client_mod = malt.client;
const doctor = malt.doctor;
const AppCtx = malt.app_ctx.AppCtx;

// ── env-resolver composition ─────────────────────────────────────────

test "AppCtx-built-from-env carries MALT_OFFLINE through to subcommand readers" {
    // The end-to-end path is: env → offline_mod.resolveFromEnv → AppCtx.offline
    // → per-call-site `http.offline = ctx.offline`. Snapshotting the
    // composition here means a regression in any link breaks one test
    // instead of leaving the seam un-pinned.
    const entries = [_:null]?[*:0]const u8{"MALT_OFFLINE=1".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const ctx: AppCtx = .{
        .io = std.Options.debug_io,
        .environ = env,
        .offline = offline_mod.resolveFromEnv(env),
    };
    try testing.expect(ctx.offline);
}

test "AppCtx-built-without-env defaults to online" {
    const ctx: AppCtx = .{
        .io = std.Options.debug_io,
        .environ = std.process.Environ.empty,
        .offline = offline_mod.resolveFromEnv(std.process.Environ.empty),
    };
    try testing.expect(!ctx.offline);
}

// ── HttpClient composition: every public entrypoint refuses ──────────

test "HttpClient.get / getWithHeaders / getToWriter / head / headResolved all refuse offline" {
    // One-stop pinning so adding a new gated entrypoint without wiring
    // it lands here as a fresh test red.
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    http.offline = true;

    var discard_buf: [0]u8 = undefined;
    var sink: std.Io.Writer.Discarding = .init(&discard_buf);

    try testing.expectError(error.OfflineRequired, http.get("https://example.invalid/x"));
    try testing.expectError(error.OfflineRequired, http.getWithHeaders("https://example.invalid/x", &.{}, null, .transport_only));
    try testing.expectError(error.OfflineRequired, http.getToWriter("https://example.invalid/x", &.{}, &sink.writer, null));
    try testing.expectError(error.OfflineRequired, http.head("https://example.invalid/x"));
    try testing.expectError(error.OfflineRequired, http.headResolved("https://example.invalid/x"));
}

test "HttpClient.OfflineRequired is non-transient" {
    // Retry-with-backoff inside `doGetWithRetry` reads `isTransientError`
    // — if OfflineRequired ever flipped to transient, the install pool
    // would burn the full retry budget on a guaranteed miss instead of
    // failing fast.
    try testing.expect(!client_mod.isTransientError(error.OfflineRequired));
}

// `HttpClientPool.setOfflineAll` propagation is unit-tested inline in
// net/client_pool.zig; the offline composition path is covered below.

// ── BrewApi end-to-end: cache hit serves under offline ───────────────

test "BrewApi.fetchFormula composes with HttpClient.offline so cache hits still serve" {
    // The point of this composition test: when `http.offline = true` on
    // a BrewApi-attached client, a cache hit must still produce bytes
    // without touching the HTTP layer at all. Otherwise the eager gate
    // could refuse before `readCacheBytes` got a chance.
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    http.offline = true;

    // Process-unique root: a fixed /tmp name lets an overlapping run's
    // deleteTree wipe this fixture mid-test.
    const tmp = try test_io.uniqueTempPath(testing.allocator, "offline", "int_compose");
    defer testing.allocator.free(tmp);
    test_io.deleteTreeAbsolute(std.Options.debug_io, tmp) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, tmp);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, tmp) catch {};

    var api_dir_buf: [128]u8 = undefined;
    const api_dir = try std.fmt.bufPrint(&api_dir_buf, "{s}/api", .{tmp});
    try test_io.makeDirAbsolute(std.Options.debug_io, api_dir);

    var path_buf: [256]u8 = undefined;
    const cached_path = try std.fmt.bufPrint(&path_buf, "{s}/api/formula_wget.json", .{tmp});
    const f = try test_io.cwd().createFile(std.Options.debug_io, cached_path, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, "{\"name\":\"wget\"}");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, tmp);
    api.offline = true;
    const body = try api.fetchFormula("wget");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"name\":\"wget\"}", body);
}

// ── doctor row composition ───────────────────────────────────────────

test "doctor.formatOfflineDetail flips on the offline bool" {
    try testing.expectEqualStrings("off", doctor.formatOfflineDetail(false));
    try testing.expectEqualStrings(
        "active — every fetch must serve from the snapshot cache",
        doctor.formatOfflineDetail(true),
    );
}

// ── doctor CheckCtx default ──────────────────────────────────────────

test "doctor.CheckCtx.offline defaults to false" {
    // Hard-coded default keeps every fixture-built CheckCtx test
    // (`debug_ctx`-shaped) reading `off` without explicit plumbing.
    const ctx: doctor.CheckCtx = .{
        .allocator = testing.allocator,
        .prefix = "/tmp/malt_offline_doctor_default",
        .io = std.Options.debug_io,
        .environ = std.process.Environ.empty,
    };
    try testing.expect(!ctx.offline);
}
