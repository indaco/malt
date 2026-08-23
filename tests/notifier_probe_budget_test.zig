//! malt — the passive version probe's budget, judged over real TLS.
//!
//! The probe fires on the hot path of every command and advertises a 1.5 s
//! bound. Its real worst case used to be the retry schedule sitting outside
//! that bound: a transiently failing endpoint bought four attempts plus seven
//! seconds of backoff, holding every command through a brownout.
//!
//! `applyProbeBudget` is what closes that, so this walks a live TLS endpoint
//! that answers 503 to everything and asserts the probe spends exactly one
//! attempt on it. Cleartext would not do: the probe's endpoint is https, and
//! a plaintext fixture would leave the handshake - the phase that actually
//! costs time - out of the measurement.
//!
//! The fixture is owned by the regression script, which generates the cert,
//! starts the server and asserts the request count it observed. Without those
//! env vars this file skips, so `zig build test` stays hermetic.

const std = @import("std");
const malt = @import("malt");
const client = malt.client;
const notifier = malt.update_notifier;
const test_io = @import("test_io");
const testing = std.testing;

/// The stock schedule sleeps 1+2+4 s across three retries. A budget between
/// the two tells "one attempt" from "four" without pinning either number.
const retry_budget_ms: i64 = 3_000;

const Fixture = struct {
    port: [:0]const u8,
    ca_path: [:0]const u8,
};

fn fixture() ?Fixture {
    return .{
        .port = test_io.getenv("MALT_TEST_PROBE_PORT") orelse return null,
        .ca_path = test_io.getenv("MALT_TEST_PROBE_CA") orelse return null,
    };
}

/// Trusts only the fixture's CA. Pinning `now` is what makes that stick:
/// stdlib otherwise rescans the system store on the first https request and
/// swaps the bundle out from under us.
fn trustFixtureCa(inner: *std.http.Client, io: std.Io, ca_path: []const u8) !void {
    const now = std.Io.Clock.real.now(io);
    try inner.ca_bundle.addCertsFromFilePathAbsolute(inner.allocator, io, now, ca_path);
    inner.now = now;
}

test "the version probe spends one attempt on an endpoint that keeps failing" {
    const fx = fixture() orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    try trustFixtureCa(&inner, io, fx.ca_path);

    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);
    notifier.applyProbeBudget(&http);

    // `localhost`, not `127.0.0.1`: certificate host verification matches DNS
    // names, and an IP SAN never satisfies it.
    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{s}/releases/latest", .{fx.port});

    const started_ms = test_io.milliTimestamp(io);
    const result = http.get(url);
    const elapsed_ms = test_io.milliTimestamp(io) - started_ms;
    http.deinit();

    var resp = try result;
    defer resp.deinit();

    try testing.expectEqual(@as(u16, 503), resp.status);
    try testing.expect(elapsed_ms < retry_budget_ms);
}

test "a transient failure is still worth retrying for everyone else" {
    // The probe's no-retry budget is the notifier's choice, not the client's
    // default. An install losing its retries to this change would be a far
    // worse regression than the latency it fixes.
    const fx = fixture() orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    try trustFixtureCa(&inner, io, fx.ca_path);

    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);
    try testing.expect(http.retry_backoff_ms.len > 0);

    // Zeroed delays: the count is the assertion, not the wall-clock.
    http.retry_backoff_ms = &.{ 0, 0, 0 };

    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{s}/retried", .{fx.port});

    const result = http.get(url);
    http.deinit();

    var resp = try result;
    defer resp.deinit();
    try testing.expectEqual(@as(u16, 503), resp.status);
}
