//! malt — offline integration test: a credential header must not follow a
//! cross-domain redirect, but must still reach the origin and survive a
//! same-host redirect. Two loopback `std.http.Server` hops on distinct host
//! strings (so stdlib's `sameParentDomain` is false) let us assert the strip
//! without any TLS fixture.

const std = @import("std");
const client = @import("malt").client;
const net = std.Io.net;

const auth_value = "token SECRET-PAT";
const blob_body = "the-protected-blob";

const Hop = struct {
    io: std.Io,
    listener: *net.Server,
    saw_auth: bool = false,
    // Request-line target the hop received (path+query), copied out of the
    // per-request read buffer so it outlives `serveOne`.
    target_buf: [512]u8 = undefined,
    target_len: usize = 0,
    // When set, answer 302 to this Location; otherwise 200 with `blob_body`.
    redirect_to: ?[]const u8 = null,
};

// Serves exactly one request. Records whether the client sent Authorization and
// the request target, then either redirects or returns the blob. Errors are
// swallowed: a failed serve surfaces as a client-side failure the test asserts on.
fn serveOne(hop: *Hop) void {
    const stream = hop.listener.accept(hop.io) catch return;
    defer stream.close(hop.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(hop.io, &rbuf);
    var writer = stream.writer(hop.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    var req = srv.receiveHead() catch return;
    const target = req.head.target;
    if (target.len <= hop.target_buf.len) {
        @memcpy(hop.target_buf[0..target.len], target);
        hop.target_len = target.len;
    }
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) hop.saw_auth = true;
    }
    if (hop.redirect_to) |loc| {
        // A non-empty 302 body exercises the redirect-body drain on hop teardown.
        req.respond("redirecting\n", .{
            .status = .found,
            .extra_headers = &.{.{ .name = "location", .value = loc }},
        }) catch return;
    } else {
        req.respond(blob_body, .{}) catch return;
    }
}

fn hopTarget(hop: *const Hop) []const u8 {
    return hop.target_buf[0..hop.target_len];
}

fn bindIp4(io: std.Io) !net.Server {
    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    return try addr.listen(io, .{ .reuse_address = true });
}

fn bindIp6(io: std.Io) !net.Server {
    var addr = try net.IpAddress.parseIp6("::1", 0);
    return try addr.listen(io, .{ .reuse_address = true });
}

test "auth headers stripped on redirect across a cross-domain hop" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // hop2 on ::1, named by "localhost" in the redirect target so its host
    // string differs from hop1's "127.0.0.1" (stdlib's same-parent-domain check
    // is false → strip). "localhost" resolves to both ::1 and 127.0.0.1 and the
    // client tries every address, so it reaches the ::1-bound hop regardless of
    // which family the resolver lists first.
    var l2 = try bindIp6(io);
    defer l2.deinit(io);
    const p2 = l2.socket.address.getPort();
    var hop2 = Hop{ .io = io, .listener = &l2 };
    const t2 = try std.Thread.spawn(.{}, serveOne, .{&hop2});

    // Redirect to a signed-URL-style target: the path and its percent-encoded
    // query must reach hop2 byte-exact (a CDN/object-store signature breaks if
    // the resolve→reissue round-trip mangles it).
    const blob_target = "/blob/sha256:abc?X-Amz-Signature=9f86d081&X-Amz-Credential=AKIA%2Fus-east-1%2Fs3&token=v2%3Dfoo%2Bbar%3D%3D";
    var loc_buf: [256]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://localhost:{d}{s}", .{ p2, blob_target });

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();
    var hop1 = Hop{ .io = io, .listener = &l1, .redirect_to = loc };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    const headers = [_]std.http.Header{.{ .name = "Authorization", .value = auth_value }};
    const result = http.getWithHeaders(url, &headers, null, .transport_only);

    // Both hops always complete the chain (pre- and post-fix), so joining
    // never hangs; join before reading server-side state.
    t1.join();
    t2.join();

    var resp = try result;
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings(blob_body, resp.body);
    // The origin must still be authenticated…
    try std.testing.expect(hop1.saw_auth);
    // …but the credential must not ride to the cross-domain target.
    try std.testing.expect(!hop2.saw_auth);
    // …and the signed path+query must survive the redirect intact.
    try std.testing.expectEqualStrings(blob_target, hopTarget(&hop2));
}

test "auth headers kept across a same-host redirect" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // hop2 on the SAME host (127.0.0.1), different port — same parent domain
    // and scheme, so the credential is preserved (e.g. github.com → github.com).
    var l2 = try bindIp4(io);
    defer l2.deinit(io);
    const p2 = l2.socket.address.getPort();
    var hop2 = Hop{ .io = io, .listener = &l2 };
    const t2 = try std.Thread.spawn(.{}, serveOne, .{&hop2});

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/blob", .{p2});

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();
    var hop1 = Hop{ .io = io, .listener = &l1, .redirect_to = loc };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    const headers = [_]std.http.Header{.{ .name = "Authorization", .value = auth_value }};
    const result = http.getWithHeaders(url, &headers, null, .transport_only);

    t1.join();
    t2.join();

    var resp = try result;
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(hop1.saw_auth);
    try std.testing.expect(hop2.saw_auth);
}
