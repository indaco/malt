//! malt — offline integration test for `HttpClient.initWith`.
//! Stands up a localhost `std.http.Server` on an ephemeral port and
//! exercises the same HTTP operations doctor's API-reachable probe
//! uses (HEAD → status) plus a GET body round-trip — proving an HTTP
//! consumer runs end-to-end without touching the real network.

const std = @import("std");
const client = @import("malt").client;
const net = std.Io.net;

const body_json = "{\"tag_name\":\"v9.9.9\"}";

const Fixture = struct {
    io: std.Io,
    listener: *net.Server,
};

// Serves exactly one request, then closes the connection. Errors are
// swallowed: a failed serve surfaces as a client-side failure in the
// test thread, which fails the assertion loudly there.
fn serveOnce(fx: *Fixture) void {
    const stream = fx.listener.accept(fx.io) catch return;
    defer stream.close(fx.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(fx.io, &rbuf);
    var writer = stream.writer(fx.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    var req = srv.receiveHead() catch return;
    req.respond(body_json, .{}) catch return;
}

test "HttpClient.initWith: GET round-trips a body from a localhost server (offline)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var fx = Fixture{ .io = io, .listener = &listener };
    const server_thread = try std.Thread.spawn(.{}, serveOnce, .{&fx});
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/releases/latest", .{port});

    // The injected client is owned by HttpClient after initWith copies it
    // in (same as init), so the caller must not deinit `inner` separately.
    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    var resp = try http.get(url);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings(body_json, resp.body);
}

test "HttpClient.initWith: HEAD probe returns the server status (doctor's API-reachable path)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var fx = Fixture{ .io = io, .listener = &listener };
    const server_thread = try std.Thread.spawn(.{}, serveOnce, .{&fx});
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/health", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    const status = try http.head(url);
    try std.testing.expectEqual(@as(u16, 200), status);
}
