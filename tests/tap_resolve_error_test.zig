//! malt — offline integration for forge-aware tap resolve-error messages.
//!
//! Inline tests in `src/core/tap.zig` cover `describeResolveError` per
//! (forge × error class) in isolation. This file pins the *assembled* path
//! that `mt tap --refresh` walks for a non-github tap: a recorded non-200
//! over the wire classifies to a `TapError` whose rendered message names
//! the tap's own host and token env var, never GitHub's. No live network —
//! a localhost server replies with the status under test.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const tap = malt.tap;
const net = std.Io.net;

const StatusFixture = struct {
    io: std.Io,
    listener: *net.Server,
    status: std.http.Status,
};

// Replies once with `fx.status` and an empty body. The resolve path
// classifies on status alone, so the body is irrelevant. Errors are
// swallowed — a failed serve surfaces as a client-side assertion miss.
fn serveStatus(fx: *StatusFixture) void {
    const stream = fx.listener.accept(fx.io) catch return;
    defer stream.close(fx.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(fx.io, &rbuf);
    var writer = stream.writer(fx.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    var req = srv.receiveHead() catch return;
    req.respond("", .{ .status = fx.status }) catch return;
}

fn listenLocal(io: std.Io) !net.Server {
    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    return addr.listen(io, .{ .reuse_address = true });
}

test "gitlab refresh over a 403 reports a forge-correct rate-limit message" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try listenLocal(io);
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var fx = StatusFixture{ .io = io, .listener = &listener, .status = .forbidden };
    const server_thread = try std.Thread.spawn(.{}, serveStatus, .{&fx});
    defer server_thread.join();

    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v4/projects/grp%2Ftap/repository/commits/HEAD", .{port});

    // The wire 403 must classify to RateLimited on the gitlab path...
    try testing.expectError(error.RateLimited, tap.resolveHeadCommit(io, .empty, testing.allocator, .gitlab, url, null));

    // ...and the message the CLI prints names the gitlab instance + token.
    var msg_buf: [512]u8 = undefined;
    const msg = tap.describeResolveError(&msg_buf, error.RateLimited, .gitlab, "gitlab.com");
    try testing.expect(std.mem.indexOf(u8, msg, "gitlab.com") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "MALT_GITLAB_TOKEN") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "MALT_GITHUB_TOKEN") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "api.github.com") == null);
}

test "gitea refresh over a 404 names the instance host and drops the github-only hint" {
    // 404 is non-retryable; a 5xx would trip the client's retry-with-backoff,
    // which a single-serve localhost server can't satisfy (the 5xx→ResolveFailed
    // classification is covered by the resolveFromConditional unit test instead).
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try listenLocal(io);
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var fx = StatusFixture{ .io = io, .listener = &listener, .status = .not_found };
    const server_thread = try std.Thread.spawn(.{}, serveStatus, .{&fx});
    defer server_thread.join();

    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/repos/grp/tap/commits?limit=1&stat=false", .{port});

    try testing.expectError(error.NotFound, tap.resolveHeadCommit(io, .empty, testing.allocator, .gitea, url, null));

    var msg_buf: [512]u8 = undefined;
    const msg = tap.describeResolveError(&msg_buf, error.NotFound, .gitea, "git.example.org");
    try testing.expect(std.mem.indexOf(u8, msg, "git.example.org") != null);
    // The homebrew-<repo>/--repo remediation is github-only; it must not leak here.
    try testing.expect(std.mem.indexOf(u8, msg, "homebrew-") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "--repo") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "GitHub") == null);
}
