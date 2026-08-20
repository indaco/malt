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
    // Non-null: answer this status, carrying `redirect_to` as Location and
    // `content_disposition` when they are set. Null: 200 with `blob_body`.
    status: ?std.http.Status = null,
    redirect_to: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
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
    if (hop.status) |status| {
        var hdrs: [2]std.http.Header = undefined;
        var n: usize = 0;
        if (hop.redirect_to) |loc| {
            hdrs[n] = .{ .name = "location", .value = loc };
            n += 1;
        }
        if (hop.content_disposition) |cd| {
            hdrs[n] = .{ .name = "content-disposition", .value = cd };
            n += 1;
        }
        // A non-empty 302 body exercises the redirect-body drain on hop
        // teardown; 304 must stay bodiless.
        const body = if (status == .found) "redirecting\n" else "";
        req.respond(body, .{ .status = status, .extra_headers = hdrs[0..n] }) catch return;
    } else if (hop.content_disposition) |cd| {
        req.respond(blob_body, .{
            .extra_headers = &.{.{ .name = "content-disposition", .value = cd }},
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

// A port bound and released again: a connection to it is refused immediately,
// so a hop the client must not take fails fast instead of hanging the test.
fn closedPort(io: std.Io) !u16 {
    var l = try bindIp4(io);
    const port = l.socket.address.getPort();
    l.deinit(io);
    return port;
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
    var hop1 = Hop{ .io = io, .listener = &l1, .redirect_to = loc, .status = .found };
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
    var hop1 = Hop{ .io = io, .listener = &l1, .redirect_to = loc, .status = .found };
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

test "headResolved follows a hop and harvests the artifact headers from it" {
    // The HEAD loop is what picks a cask's artifact type, and it was the one
    // redirect loop with no fixture coverage. The scheme-relative Location also
    // pins that a hop is resolved against the base rather than taken verbatim.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cd = "attachment; filename=\"artifact.zip\"";
    var l2 = try bindIp4(io);
    defer l2.deinit(io);
    const p2 = l2.socket.address.getPort();
    var hop2 = Hop{ .io = io, .listener = &l2, .content_disposition = cd };
    const t2 = try std.Thread.spawn(.{}, serveOne, .{&hop2});

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "//127.0.0.1:{d}/artifact", .{p2});

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();
    var hop1 = Hop{ .io = io, .listener = &l1, .redirect_to = loc, .status = .found };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    const result = http.headResolved(url);

    t1.join();
    t2.join();

    var resolved = try result;
    defer resolved.deinit();

    var want_buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "http://127.0.0.1:{d}/artifact", .{p2});
    try std.testing.expectEqualStrings(want, resolved.final_url);
    try std.testing.expectEqualStrings(cd, resolved.content_disposition.?);
    try std.testing.expectEqualStrings("/artifact", hopTarget(&hop2));
}

// Stands up one hop answering `status` with a Location pointing at a dead
// port, and returns what `headResolved` made of it.
fn resolveAgainstNonRedirect(status: std.http.Status) !void {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/artifact.pkg", .{try closedPort(io)});

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();
    var hop1 = Hop{ .io = io, .listener = &l1, .redirect_to = loc, .status = status };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    const result = http.headResolved(url);
    t1.join();

    var resolved = try result;
    defer resolved.deinit();

    // Unchanged: the hop was terminal, so the walk never moved off the origin.
    try std.testing.expectEqualStrings(url, resolved.final_url);
}

test "headResolved does not follow Location on a non-redirect status" {
    // 304, 305 and 306 sit inside the 301..308 range but none is a redirect.
    // The port each one points at is never bound, so a follow is unmistakable.
    try resolveAgainstNonRedirect(.not_modified);
    try resolveAgainstNonRedirect(.use_proxy);
    try resolveAgainstNonRedirect(@enumFromInt(306));
}

test "headResolved reports an unreachable origin instead of the untouched url" {
    // The pre-fix loop returned the caller's own url here, which the cask
    // installer classified as an unreadable format rather than a dead network.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/download", .{try closedPort(io)});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    try std.testing.expectError(error.RequestFailed, http.headResolved(url));
}

test "headResolved reports a dead hop instead of a half-walked resolution" {
    // Hop 1 hands over a Content-Disposition on its way to a dead hop 2.
    // Returning that harvested header against a stale final_url would let a
    // cask be classified from partial data.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/artifact", .{try closedPort(io)});

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();
    var hop1 = Hop{
        .io = io,
        .listener = &l1,
        .redirect_to = loc,
        .status = .found,
        .content_disposition = "attachment; filename=\"artifact.pkg\"",
    };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    const result = http.headResolved(url);
    t1.join();

    try std.testing.expectError(error.RequestFailed, result);
}

test "headResolved reports a redirect with no Location instead of the pre-hop url" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();
    var hop1 = Hop{ .io = io, .listener = &l1, .status = .moved_permanently };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    const result = http.headResolved(url);
    t1.join();

    try std.testing.expectError(error.HttpRedirectLocationMissing, result);
}
