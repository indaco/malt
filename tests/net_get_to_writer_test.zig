//! malt — offline integration tests for `HttpClient.getToWriter`, the
//! streaming GET that drains a 200 body straight into a caller-provided
//! `*std.Io.Writer` and returns only the status. Each test stands up a
//! localhost `std.http.Server` (the same loopback transport the other net
//! tests use), so no real network is touched.
//!
//! The invariant under test is the retry × stateful-sink policy: the sink is
//! written *only* once the response is a definitive 200, and a mid-200-stream
//! transport failure surfaces to the caller instead of being retried into the
//! now-dirty sink.

const std = @import("std");
const client = @import("malt").client;
const net = std.Io.net;

const body_200 = "STREAMED-BOTTLE-BYTES-0123456789-ABCDEF";

const Mode = enum {
    /// Every GET answers 200 with `body_200`.
    ok,
    /// First GET answers 503 (a transient error net retries), later ones 200.
    err_then_ok,
    /// First GET answers 401 (a non-transient status the caller re-auths on),
    /// later ones 200 — mirrors GHCR's re-auth handshake.
    unauth_then_ok,
    /// A 200 that sends one chunk then drops the connection without the
    /// terminating chunk: the client's body read fails mid-stream.
    truncated,
    /// First GET answers a 302 to `/final`; the followed GET answers 200 —
    /// exercises the streaming redirect loop.
    redirect_then_ok,
};

const Stub = struct {
    io: std.Io,
    listener: *net.Server,
    mode: Mode,
    get_count: usize = 0,
};

// Serves the request sequence on one keep-alive connection, looping until the
// client closes (which surfaces as a `receiveHead` error). The truncated mode
// closes the connection itself after a short partial body.
fn serve(s: *Stub) void {
    const stream = s.listener.accept(s.io) catch return;
    defer stream.close(s.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(s.io, &rbuf);
    var writer = stream.writer(s.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var req = srv.receiveHead() catch return;
        const target = req.head.target;
        s.get_count += 1;
        switch (s.mode) {
            .ok => req.respond(body_200, .{}) catch return,
            .redirect_then_ok => if (std.mem.indexOf(u8, target, "/final") != null)
                req.respond(body_200, .{}) catch return
            else
                req.respond("", .{
                    .status = .found,
                    .extra_headers = &.{.{ .name = "location", .value = "/final" }},
                }) catch return,
            .err_then_ok => if (s.get_count == 1)
                req.respond("service unavailable\n", .{ .status = .service_unavailable }) catch return
            else
                req.respond(body_200, .{}) catch return,
            .unauth_then_ok => if (s.get_count == 1)
                req.respond("unauthorized\n", .{ .status = .unauthorized }) catch return
            else
                req.respond(body_200, .{}) catch return,
            .truncated => {
                // Chunked 200: emit one chunk, flush it, then drop the socket
                // without the terminating 0-chunk so the client's body read
                // fails mid-stream.
                var body_buf: [64]u8 = undefined;
                var bw = req.respondStreaming(&body_buf, .{}) catch return;
                bw.writer.writeAll("partial") catch return;
                bw.flush() catch return;
                return;
            },
        }
    }
}

test "getToWriter streams a 200 body into the caller sink and returns 200" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener, .mode = .ok };
    const server_thread = try std.Thread.spawn(.{}, serve, .{&stub});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/blobs/sha256:abc", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const status = http.getToWriter(url, &.{}, &sink.writer, null);

    http.deinit();
    server_thread.join();

    try std.testing.expectEqual(@as(u16, 200), try status);
    try std.testing.expectEqualStrings(body_200, sink.writer.buffered());
}

test "getWithHeaders remains byte-identical against the same fixture (buffer path guard)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener, .mode = .ok };
    const server_thread = try std.Thread.spawn(.{}, serve, .{&stub});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/blobs/sha256:abc", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    const result = http.getWithHeaders(url, &.{}, null);

    http.deinit();
    server_thread.join();

    var resp = try result;
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    // The buffer wrapper still returns the whole body as an owned slice.
    try std.testing.expectEqualStrings(body_200, resp.body);
}

test "getToWriter drains a non-200 to a throwaway, keeps the sink pristine, streams the 200 on retry" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener, .mode = .err_then_ok };
    const server_thread = try std.Thread.spawn(.{}, serve, .{&stub});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/blobs/sha256:abc", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const status = http.getToWriter(url, &.{}, &sink.writer, null);

    http.deinit();
    server_thread.join();

    // net retried the transient 503 internally and reached the 200.
    try std.testing.expectEqual(@as(u16, 200), try status);
    // The 503 error page never reached the caller's sink.
    try std.testing.expectEqualStrings(body_200, sink.writer.buffered());
    try std.testing.expectEqual(@as(usize, 2), stub.get_count);
}

test "getToWriter keeps the sink pristine across a caller-driven 401 re-auth" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener, .mode = .unauth_then_ok };
    const server_thread = try std.Thread.spawn(.{}, serve, .{&stub});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/blobs/sha256:abc", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    // First attempt: 401 is non-transient, so net returns it without retrying
    // and without touching the sink — exactly what lets the caller re-auth.
    const first = http.getToWriter(url, &.{}, &sink.writer, null);
    try std.testing.expectEqual(@as(u16, 401), try first);
    try std.testing.expectEqual(@as(usize, 0), sink.writer.buffered().len);

    // Caller re-issues (as GHCR does with a fresh bearer): now the sink fills
    // once with the 200 body — never the 401 page.
    const second = http.getToWriter(url, &.{}, &sink.writer, null);

    http.deinit();
    server_thread.join();

    try std.testing.expectEqual(@as(u16, 200), try second);
    try std.testing.expectEqualStrings(body_200, sink.writer.buffered());
}

test "getToWriter surfaces a mid-200-stream transport failure without retrying" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener, .mode = .truncated };
    const server_thread = try std.Thread.spawn(.{}, serve, .{&stub});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/blobs/sha256:abc", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const status = http.getToWriter(url, &.{}, &sink.writer, null);

    http.deinit();
    server_thread.join();

    // A typed transport error, not a status; the sink was written at most once.
    try std.testing.expectError(error.ReadFailed, status);
    // The commit-to-sink was single-shot: net did NOT re-issue the GET.
    try std.testing.expectEqual(@as(usize, 1), stub.get_count);
}

// Records the final progress report so a test can prove the callback fires on
// the streaming path (not just the legacy buffer path).
const ProgressRec = struct {
    calls: usize = 0,
    last_bytes: u64 = 0,
    last_len: ?u64 = null,

    fn record(ctx: *anyopaque, bytes_so_far: u64, content_length: ?u64) void {
        const self: *ProgressRec = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_bytes = bytes_so_far;
        self.last_len = content_length;
    }
};

test "getToWriter reports progress as the 200 body streams into the sink" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener, .mode = .ok };
    const server_thread = try std.Thread.spawn(.{}, serve, .{&stub});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/blobs/sha256:abc", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    var rec = ProgressRec{};
    const progress = client.ProgressCallback{ .context = &rec, .func = ProgressRec.record };
    const status = http.getToWriter(url, &.{}, &sink.writer, progress);

    http.deinit();
    server_thread.join();

    try std.testing.expectEqual(@as(u16, 200), try status);
    // The callback fired and its final tally matches the streamed body — the
    // progress plumbing rides the sink path, not just the buffer path.
    try std.testing.expect(rec.calls >= 1);
    try std.testing.expectEqual(@as(u64, body_200.len), rec.last_bytes);
    try std.testing.expectEqual(@as(u64, body_200.len), rec.last_len.?);
}

test "getToWriter follows a redirect and streams only the final 200 body into the sink" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener, .mode = .redirect_then_ok };
    const server_thread = try std.Thread.spawn(.{}, serve, .{&stub});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/blobs/sha256:abc", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const status = http.getToWriter(url, &.{}, &sink.writer, null);

    http.deinit();
    server_thread.join();

    try std.testing.expectEqual(@as(u16, 200), try status);
    // The 302 has an empty body; only the followed 200 reaches the sink.
    try std.testing.expectEqualStrings(body_200, sink.writer.buffered());
    try std.testing.expectEqual(@as(usize, 2), stub.get_count);
}
