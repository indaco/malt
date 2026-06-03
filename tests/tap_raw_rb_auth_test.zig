//! malt — offline integration test for tap raw-`.rb` fetch auth.
//! Stands up a localhost `std.http.Server` that records the request's
//! Authorization header, then drives `tap.getRawFile` to prove GitHub's
//! raw fetch stays unauthenticated even when `MALT_GITHUB_TOKEN` is set:
//! the API token belongs to api.github.com, not the raw CDN, so routing
//! raw through the forge seam must not widen the token's reach. Forges
//! whose raw lives on the authenticated instance host attach their token
//! via `forge.rawAuthHeader`; that positive path arrives with those arms.

const std = @import("std");
const malt = @import("malt");
const client = malt.client;
const tap = malt.tap;
const net = std.Io.net;

const body_rb = "class Glow < Formula\nend\n";

const Fixture = struct {
    io: std.Io,
    listener: *net.Server,
    saw_auth: bool = false,
};

// Serves one request, recording whether it carried an Authorization
// header before responding. Errors are swallowed: a failed serve
// surfaces as a client-side assertion failure in the test thread.
fn serveOnce(fx: *Fixture) void {
    const stream = fx.listener.accept(fx.io) catch return;
    defer stream.close(fx.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(fx.io, &rbuf);
    var writer = stream.writer(fx.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    var req = srv.receiveHead() catch return;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) fx.saw_auth = true;
    }
    req.respond(body_rb, .{}) catch return;
}

fn envWithToken() std.process.Environ {
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=ghp_rawtoken"};
    return .{ .block = .{ .slice = entries[0..1 :null] } };
}

test "getRawFile: github raw fetch carries no auth header even with MALT_GITHUB_TOKEN set" {
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

    var url_buf: [80]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/Formula/glow.rb", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, envWithToken(), std.testing.allocator);
    defer http.deinit();

    var resp = try tap.getRawFile(&http, envWithToken(), .github, url);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings(body_rb, resp.body);
    // The API token must not ride the raw fetch — github raw is unchanged.
    try std.testing.expect(!fx.saw_auth);
}
