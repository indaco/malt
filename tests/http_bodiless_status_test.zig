//! malt — bodiless-status release integration tests.
//!
//! A 204 or 304 carries no body, and real servers send them with no
//! Content-Length and no Transfer-Encoding either. The stdlib release path
//! decides whether to drain by request *method*, so unless the response is
//! declared zero-length it reads until the peer closes — on a keep-alive
//! connection that is a full idle timeout per request.
//!
//! The stub below answers with raw bytes (no framing headers) and then holds
//! the connection open: closing it would let the drain hit EOF and hide the
//! very stall these tests exist to catch. A regression shows up as a
//! multi-second wall time, not a wrong value.

const std = @import("std");
const client = @import("malt").client;
const net = std.Io.net;
const testing = std.testing;

/// A healthy release returns in milliseconds. A regressed one blocks until
/// the stub gives up, so the budget sits between the two.
const stall_budget_ms: i64 = 3_000;

/// How long the stub keeps a bodiless response's connection open. Bounds the
/// damage of a regression: the drain ends at EOF here instead of hanging the
/// suite, and the elapsed assertion then fails cleanly.
const hold_open_ms: i32 = 6_000;

const Stub = struct {
    io: std.Io,
    listener: *net.Server,
    /// Full response head, terminated by a blank line. Deliberately carries
    /// no Content-Length and no Transfer-Encoding.
    head: []const u8,
};

fn serveBodiless(s: *Stub) void {
    const stream = s.listener.accept(s.io) catch return;
    defer stream.close(s.io);

    var rbuf: [8 * 1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var reader = stream.reader(s.io, &rbuf);
    var writer = stream.writer(s.io, &wbuf);

    // One blocking read is enough: the client's whole GET head arrives in a
    // single loopback segment, and it has already finished writing by then.
    _ = reader.interface.peek(1) catch return;

    writer.interface.writeAll(s.head) catch return;
    writer.interface.flush() catch return;

    // Hold the connection open: an undeclared body has nothing to read, which
    // is the keep-alive condition the bug needs. A healthy client closes at
    // once and `poll` returns immediately; a regressed one is still blocked,
    // so the wait is bounded rather than infinite.
    var pfds = [_]std.posix.pollfd{.{
        .fd = stream.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    _ = std.posix.poll(&pfds, hold_open_ms) catch {};
}

const Probe = struct { status: u16, not_modified: bool, elapsed_ms: i64 };

fn runBodiless(head: []const u8, if_none_match: ?[]const u8) !Probe {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener, .head = head };
    const server_thread = try std.Thread.spawn(.{}, serveBodiless, .{&stub});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/probe", .{port});

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);

    const started_ns: i128 = std.Io.Clock.real.now(io).toNanoseconds();
    var resp = try http.getConditional(url, if_none_match, &.{});
    const elapsed: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).toNanoseconds() - started_ns, std.time.ns_per_ms));
    defer resp.deinit();

    const out = Probe{ .status = resp.status, .not_modified = resp.not_modified, .elapsed_ms = elapsed };

    http.deinit();
    server_thread.join();
    return out;
}

test "a 304 with no framing headers is released without draining the connection" {
    const r = try runBodiless("HTTP/1.1 304 Not Modified\r\nETag: W/\"deadbeef\"\r\n\r\n", "W/\"deadbeef\"");

    try testing.expectEqual(@as(u16, 304), r.status);
    try testing.expect(r.not_modified);
    if (r.elapsed_ms >= stall_budget_ms) {
        std.debug.print("304 took {d}ms — the release path drained a body that never comes\n", .{r.elapsed_ms});
        return error.ConditionalRequestStalled;
    }
}

test "a 204 with no framing headers is released without draining the connection" {
    // Same rule, different status: not_modified stays false so a 204 is never
    // mistaken for a validated cache hit.
    const r = try runBodiless("HTTP/1.1 204 No Content\r\n\r\n", null);

    try testing.expectEqual(@as(u16, 204), r.status);
    try testing.expect(!r.not_modified);
    if (r.elapsed_ms >= stall_budget_ms) {
        std.debug.print("204 took {d}ms — the release path drained a body that never comes\n", .{r.elapsed_ms});
        return error.BodilessResponseStalled;
    }
}
