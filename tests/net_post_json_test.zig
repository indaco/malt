//! malt — `HttpClient.postJson` integration tests.
//!
//! A loopback `std.http.Server` records what the client sent, so the tests
//! pin the wire contract (method, content type, framed body) and that a
//! redirect is refused rather than replayed at another origin.

const std = @import("std");
const testing = std.testing;
const net = std.Io.net;
const client = @import("malt").client;

const Peer = struct {
    io: std.Io,
    listener: *net.Server,
    status: std.http.Status,
    body: []const u8,
    seen_method: ?std.http.Method = null,
    seen_content_type: [64]u8 = undefined,
    seen_content_type_len: usize = 0,
    seen_body: [256]u8 = undefined,
    seen_body_len: usize = 0,

    fn serveOne(p: *Peer) void {
        const stream = p.listener.accept(p.io) catch return;
        defer stream.close(p.io);
        var rbuf: [8 * 1024]u8 = undefined;
        var wbuf: [4 * 1024]u8 = undefined;
        var reader = stream.reader(p.io, &rbuf);
        var writer = stream.writer(p.io, &wbuf);
        var srv = std.http.Server.init(&reader.interface, &writer.interface);
        var req = srv.receiveHead() catch return;
        p.seen_method = req.head.method;
        if (req.head.content_type) |ct| {
            const n = @min(ct.len, p.seen_content_type.len);
            @memcpy(p.seen_content_type[0..n], ct[0..n]);
            p.seen_content_type_len = n;
        }
        var body_buf: [1024]u8 = undefined;
        const body = req.readerExpectNone(&body_buf);
        p.seen_body_len = body.readSliceShort(&p.seen_body) catch 0;
        const extra: []const std.http.Header = if (p.status.class() == .redirect)
            &.{.{ .name = "Location", .value = "/elsewhere" }}
        else
            &.{};
        req.respond(p.body, .{ .status = p.status, .extra_headers = extra }) catch return;
    }
};

fn post(peer_status: std.http.Status, peer_body: []const u8, sent: []const u8, max_bytes: usize, out: *Peer) !client.GetError!client.Response {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    out.* = .{ .io = io, .listener = &listener, .status = peer_status, .body = peer_body };
    const thread = try std.Thread.spawn(.{}, Peer.serveOne, .{out});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/querybatch", .{port});
    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    http.retry_backoff_ms = &.{};

    const result = http.postJson(url, sent, max_bytes);
    thread.join();
    return result;
}

test "postJson sends the body as application/json and returns the response" {
    var peer: Peer = undefined;
    var resp = try (try post(.ok, "{\"results\":[]}", "{\"queries\":[]}", 64 * 1024, &peer));
    defer resp.deinit();

    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("{\"results\":[]}", resp.body);
    try testing.expectEqual(std.http.Method.POST, peer.seen_method.?);
    try testing.expectEqualStrings("application/json", peer.seen_content_type[0..peer.seen_content_type_len]);
    try testing.expectEqualStrings("{\"queries\":[]}", peer.seen_body[0..peer.seen_body_len]);
}

test "postJson refuses a redirect instead of replaying the body elsewhere" {
    var peer: Peer = undefined;
    try testing.expectError(error.RequestFailed, try post(.found, "", "{\"queries\":[]}", 64 * 1024, &peer));
}

test "postJson caps the response like every other metadata read" {
    var peer: Peer = undefined;
    try testing.expectError(error.ResponseTooLarge, try post(.ok, "0123456789", "{}", 4, &peer));
}
