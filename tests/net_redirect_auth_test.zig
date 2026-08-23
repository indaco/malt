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
    // When set, the hop redirects this many times and answers 200 after, so a
    // single hop can stand in for a whole chain.
    redirects_left: ?usize = null,
    // Drop the first request without answering it, so an otherwise healthy hop
    // hands the client one transport failure.
    fail_first: bool = false,
    // Read the request and never answer it, holding the connection open: the
    // connected-but-silent origin the head-phase deadline exists for.
    stall: bool = false,
    // Answer, but only after burning this much of the hop's budget. Lets a
    // test spend more than one budget's worth across a chain while leaving
    // every single hop comfortably inside its own.
    answer_delay_ns: u64 = 0,
    // Requests actually received, so a test can assert how many walks happened.
    requests: usize = 0,
    // Mirrors `requests` for the cancel probes, which read it from the client
    // thread while this one is still running.
    served: std.atomic.Value(usize) = .init(0),
};

fn serveOne(hop: *Hop) void {
    serveCount(hop, 1);
}

// Serves `count` requests, reusing a kept-alive connection and accepting a
// fresh one when the client drops it. Errors are swallowed: a failed serve
// surfaces as a client-side failure the test asserts on.
fn serveCount(hop: *Hop, count: usize) void {
    var served: usize = 0;
    while (served < count) {
        const stream = hop.listener.accept(hop.io) catch return;
        defer stream.close(hop.io);
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(hop.io, &rbuf);
        var writer = stream.writer(hop.io, &wbuf);
        var srv = std.http.Server.init(&reader.interface, &writer.interface);
        var served_here = false;
        while (served < count) {
            var req = srv.receiveHead() catch break;
            served_here = true;
            served += 1;
            hop.requests += 1;
            _ = hop.served.fetchAdd(1, .release);
            if (hop.fail_first) {
                hop.fail_first = false;
                break; // close mid-request: the client sees a dead connection
            }
            if (hop.answer_delay_ns > 0) {
                std.Io.sleep(hop.io, std.Io.Duration.fromNanoseconds(@intCast(hop.answer_delay_ns)), .awake) catch {};
            }
            if (hop.stall) {
                // Park until the client gives up and drops the socket. Nothing
                // else can end this wait, which is the point of the fixture.
                _ = reader.interface.peekByte() catch {};
                return;
            }
            answer(hop, &req);
        }
        // A connection carrying no request is `knock`: the client is done, so
        // stop waiting for requests it is never going to send.
        if (!served_here) return;
    }
}

// Serves `count` requests, then refuses: every further connection is accepted
// and closed at once. `serveCount` stops accepting at its quota, so an extra
// dial would block on the listen backlog instead of failing the test's count
// assertion. Ends on `knock`, like its bounded sibling.
fn serveCountThenRefuse(hop: *Hop, count: usize) void {
    serveCount(hop, count);
    // Knocked before the quota ran out: the test is already finished.
    if (hop.requests < count) return;
    while (true) {
        const stream = hop.listener.accept(hop.io) catch return;
        defer stream.close(hop.io);
        var rbuf: [1024]u8 = undefined;
        var reader = stream.reader(hop.io, &rbuf);
        // A connection carrying no request is `knock`: the test is done.
        _ = reader.interface.peekByte() catch return;
    }
}

// Wakes a hop still parked in `accept`. Without it, a client that dials fewer
// times than the fixture expects hangs the test instead of failing it - and CI
// has no per-test timeout to cut that short.
fn knock(io: std.Io, port: u16) void {
    var addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return;
    const s = addr.connect(io, .{ .mode = .stream }) catch return;
    s.close(io);
}

// Records whether the client sent Authorization and the request target, then
// either redirects or returns the blob.
fn answer(hop: *Hop, req: *std.http.Server.Request) void {
    const target = req.head.target;
    if (target.len <= hop.target_buf.len) {
        @memcpy(hop.target_buf[0..target.len], target);
        hop.target_len = target.len;
    }
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) hop.saw_auth = true;
    }
    if (hop.redirects_left) |*left| {
        if (left.* == 0) hop.status = null else left.* -= 1;
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

// A hop that answers a redirect carrying neither `Content-Length` nor a
// transfer encoding, then holds the socket open. The body is close-delimited,
// so the drain a plain release performs has no end.
const UnframedRedirectPeer = struct {
    io: std.Io,
    listener: *net.Server,
    location: []const u8,
};

// Bounds a regression: the drain hits EOF here instead of hanging the suite,
// so the wall-clock assertion fails cleanly.
const hold_open_ms: i32 = 6_000;

// A healthy release returns in milliseconds; a draining one waits out
// `hold_open_ms`. The budget sits between the two.
const drain_budget_ms: i64 = 3_000;

fn serveUnframedRedirect(peer: *UnframedRedirectPeer) void {
    const stream = peer.listener.accept(peer.io) catch return;
    defer stream.close(peer.io);

    var rbuf: [8 * 1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var reader = stream.reader(peer.io, &rbuf);
    var writer = stream.writer(peer.io, &wbuf);

    // One blocking read is enough: the client's whole GET head arrives in a
    // single loopback segment.
    _ = reader.interface.peek(1) catch return;

    writer.interface.print(
        "HTTP/1.1 302 Found\r\nLocation: {s}\r\n\r\nredirecting\n",
        .{peer.location},
    ) catch return;
    writer.interface.flush() catch return;

    // Hold it open: an undeclared body ends at close, which is the condition
    // the bug needs. A healthy client hangs up at once and `poll` returns
    // immediately.
    var pfds = [_]std.posix.pollfd{.{
        .fd = stream.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    _ = std.posix.poll(&pfds, hold_open_ms) catch {};
}

// A peer that completes the TCP accept and then never speaks TLS. `Hop` cannot
// stand in for it: the client parks inside `client.request` before any request
// line is written, so an `http.Server` has nothing to read.
const TlsSilentPeer = struct {
    io: std.Io,
    listener: *net.Server,
    accepts: std.atomic.Value(usize) = .init(0),
};

fn acceptAndSayNothing(peer: *TlsSilentPeer) void {
    const stream = peer.listener.accept(peer.io) catch return;
    defer stream.close(peer.io);
    _ = peer.accepts.fetchAdd(1, .release);
    // Hold the connection until the client hangs up, so the handshake stalls
    // instead of failing fast on a reset.
    var rbuf: [64]u8 = undefined;
    var reader = stream.reader(peer.io, &rbuf);
    _ = reader.interface.discardRemaining() catch {};
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
    // The subject is the error surfaced, not the retry that precedes it.
    http.retry_backoff_ms = &.{};

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
    // One walk only: hop 1 serves a single request, and the dead hop 2 behind it
    // is what this asserts on.
    http.retry_backoff_ms = &.{};

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
    // Refusing rather than bounded: a missing Location is settled by the
    // response, so a walk that retried it would fail here instead of stalling.
    const t1 = try std.Thread.spawn(.{}, serveCountThenRefuse, .{ &hop1, 1 });

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    const result = http.headResolved(url);
    // Drop the client, then knock: a refusing hop only stops on the knock.
    http.deinit();
    knock(io, p1);
    t1.join();

    try std.testing.expectError(error.HttpRedirectLocationMissing, result);
}

test "headResolved reports an exhausted redirect walk instead of an un-fetched url" {
    // A hop that redirects to itself burns the whole cap without ever reaching
    // a terminal response, so the url the walk ends on was never requested -
    // and the cask installer would raise a sudo prompt on the strength of it.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/loop", .{p1});
    // The Content-Disposition also puts the error path's cleanup under the
    // testing allocator.
    var hop1 = Hop{
        .io = io,
        .listener = &l1,
        .redirect_to = loc,
        .status = .found,
        .content_disposition = "attachment; filename=\"artifact.pkg\"",
    };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    // One walk's worth of requests; a second walk is refused rather than left
    // to stall, so a loop that retries the tripped cap fails the count below.
    const one_walk = client.HttpClient.max_redirects + 1;
    const t1 = try std.Thread.spawn(.{}, serveCountThenRefuse, .{ &hop1, one_walk });

    const result = http.headResolved(url);
    // Drop the client first: the hop is parked reading the kept-alive
    // connection, and only closing it lets the hop reach `knock`.
    http.deinit();
    knock(io, p1);
    t1.join();

    try std.testing.expectError(error.TooManyHttpRedirects, result);
    // A spent budget is a property of the chain: re-walking it only delays the
    // same answer.
    try std.testing.expectEqual(one_walk, hop1.requests);
}

test "headResolved resolves a chain as long as the download can follow" {
    // Guards against over-correcting: a chain the download would follow to the
    // end must still classify. Expressed in the download's budget so retuning
    // it moves both loops together.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/loop", .{p1});
    var hop1 = Hop{
        .io = io,
        .listener = &l1,
        .redirect_to = loc,
        .status = .found,
        .redirects_left = client.HttpClient.max_redirects,
    };
    const t1 = try std.Thread.spawn(.{}, serveCount, .{ &hop1, client.HttpClient.max_redirects + 1 });

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    const result = http.headResolved(url);
    http.deinit();
    knock(io, p1);
    t1.join();

    var resolved = try result;
    defer resolved.deinit();

    try std.testing.expectEqualStrings(loc, resolved.final_url);
}

test "headResolved refuses a chain one hop longer than the download can follow" {
    // The window this closes: classifying a cask - possibly as `.pkg`, which
    // raises the sudo installer prompt - from a chain the download then
    // rejects. One hop past the download's budget must never resolve.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/loop", .{p1});
    var hop1 = Hop{
        .io = io,
        .listener = &l1,
        .redirect_to = loc,
        .status = .found,
        .redirects_left = client.HttpClient.max_redirects + 1,
    };
    // Serves one request more than the walk may spend, so a loop that follows
    // the extra hop reaches a terminal 200 and resolves instead of hanging;
    // refusing after that keeps a retried cap trip from stalling either.
    const t1 = try std.Thread.spawn(.{}, serveCountThenRefuse, .{ &hop1, client.HttpClient.max_redirects + 2 });

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    const result = http.headResolved(url);
    http.deinit();
    knock(io, p1);
    t1.join();

    // Assert before releasing: on failure `expectError` formats the payload,
    // and a freed `final_url` would crash the report instead of printing it.
    defer if (result) |r| {
        var resolved = r;
        resolved.deinit();
    } else |_| {};
    try std.testing.expectError(error.TooManyHttpRedirects, result);
}

test "a download follows a chain the full length of the shared redirect budget" {
    // The other half of the invariant: the HEAD walk is only allowed to resolve
    // what the download reaches, so the download must actually reach it.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/loop", .{p1});
    var hop1 = Hop{
        .io = io,
        .listener = &l1,
        .redirect_to = loc,
        .status = .found,
        .redirects_left = client.HttpClient.max_redirects,
    };
    const t1 = try std.Thread.spawn(.{}, serveCount, .{ &hop1, client.HttpClient.max_redirects + 1 });

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    const result = http.getWithHeaders(url, &.{}, null, .transport_only);
    http.deinit();
    knock(io, p1);
    t1.join();

    const resp = try result;
    defer resp.allocator.free(resp.body);

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings(blob_body, resp.body);
}

test "a streaming download follows a chain the full length of the shared redirect budget" {
    // The bottle path streams rather than buffers, and it walks redirects on
    // its own; without this it is the only walk whose hop following is untested.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/loop", .{p1});
    var hop1 = Hop{
        .io = io,
        .listener = &l1,
        .redirect_to = loc,
        .status = .found,
        .redirects_left = client.HttpClient.max_redirects,
    };
    const t1 = try std.Thread.spawn(.{}, serveCount, .{ &hop1, client.HttpClient.max_redirects + 1 });

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const status = http.getToWriter(url, &.{}, &sink.writer, null);
    http.deinit();
    knock(io, p1);
    t1.join();

    try std.testing.expectEqual(@as(u16, 200), try status);
    try std.testing.expectEqualStrings(blob_body, sink.writer.buffered());
}

test "a streaming download names an over-long chain rather than calling it malformed" {
    // The streaming walk maps hop failures into its own error set, where an
    // exhausted budget is one `else` arm away from being reported as a
    // malformed redirect - a different fault with a different remedy.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/loop", .{p1});
    var hop1 = Hop{
        .io = io,
        .listener = &l1,
        .redirect_to = loc,
        .status = .found,
    };
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    // One walk's worth of requests; a second walk is refused rather than left
    // to stall, so a loop that re-walks a spent cap fails the count below.
    const one_walk = client.HttpClient.max_redirects + 1;
    const t1 = try std.Thread.spawn(.{}, serveCountThenRefuse, .{ &hop1, one_walk });

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const status = http.getToWriter(url, &.{}, &sink.writer, null);
    http.deinit();
    knock(io, p1);
    t1.join();

    try std.testing.expectError(error.TooManyHttpRedirects, status);
    try std.testing.expectEqualStrings("", sink.writer.buffered());
    // The download side of the same rule: no backoff spent on a chain whose
    // budget is already gone.
    try std.testing.expectEqual(one_walk, hop1.requests);
}

test "a buffered download spends one walk on a chain whose budget is gone" {
    // The third retry loop. Its two siblings are covered above; without this
    // the buffered GET could keep re-walking a spent budget unnoticed.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/loop", .{p1});
    var hop1 = Hop{ .io = io, .listener = &l1, .redirect_to = loc, .status = .found };

    const one_walk = client.HttpClient.max_redirects + 1;
    const t1 = try std.Thread.spawn(.{}, serveCountThenRefuse, .{ &hop1, one_walk });

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    const result = http.getWithHeaders(url, &.{}, null, .transport_only);
    http.deinit();
    knock(io, p1);
    t1.join();

    try std.testing.expectError(error.TooManyHttpRedirects, result);
    try std.testing.expectEqual(one_walk, hop1.requests);
}

test "a buffered download survives a hop that fails once" {
    // The mirror of the classification test: the shared predicate is unit
    // tested, but only a live fixture proves each loop is wired to it.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var hop1 = Hop{ .io = io, .listener = &l1, .fail_first = true };
    const t1 = try std.Thread.spawn(.{}, serveCount, .{ &hop1, 2 });

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/blob", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.retry_backoff_ms = &.{0};

    const result = http.getWithHeaders(url, &.{}, null, .transport_only);
    http.deinit();
    knock(io, p1);
    t1.join();

    var resp = try result;
    defer resp.deinit();
    try std.testing.expectEqualStrings(blob_body, resp.body);
    try std.testing.expectEqual(@as(usize, 2), hop1.requests);
}

test "a url that cannot be parsed fails without spending the retry budget" {
    // Deterministic: no attempt can parse what the first one could not. The
    // walks used to call this a transport fault, which is retriable, so a
    // malformed manifest url cost the whole backoff before failing.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    // This pins the tag each walk reports; that the tag is terminal is asserted
    // against the predicate in client.zig, where it can be checked directly.
    // Passes the scheme guard, then fails `std.Uri.parse` on the port.
    const bad = "https://example.com:port/artifact";
    try std.testing.expectError(error.InvalidUrl, http.headResolved(bad));
    try std.testing.expectError(error.InvalidUrl, http.getWithHeaders(bad, &.{}, null, .transport_only));

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try std.testing.expectError(error.InvalidUrl, http.getToWriter(bad, &.{}, &sink.writer, null));
}

test "a retried walk starts over at the origin rather than resuming mid-chain" {
    // What makes retrying a classification safe: a fresh walk, not a resumed
    // one. Resuming would hand back a url no attempt requested end to end -
    // the half-walked resolution the cask installer must never classify from.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    var l2 = try bindIp4(io);
    defer l2.deinit(io);
    const p1 = l1.socket.address.getPort();
    const p2 = l2.socket.address.getPort();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/artifact", .{p2});
    const cd = "attachment; filename=\"artifact.dmg\"";
    var hop1 = Hop{
        .io = io,
        .listener = &l1,
        .redirect_to = loc,
        .status = .found,
        .content_disposition = cd,
    };
    // Hop 2 drops the first request: the retry has to come back through hop 1.
    var hop2 = Hop{ .io = io, .listener = &l2, .fail_first = true };
    const t1 = try std.Thread.spawn(.{}, serveCount, .{ &hop1, 2 });
    const t2 = try std.Thread.spawn(.{}, serveCount, .{ &hop2, 2 });

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.retry_backoff_ms = &.{0};

    const result = http.headResolved(url);
    http.deinit();
    knock(io, p1);
    knock(io, p2);
    t1.join();
    t2.join();

    var resolved = try result;
    defer resolved.deinit();

    try std.testing.expectEqualStrings(loc, resolved.final_url);
    try std.testing.expectEqualStrings(cd, resolved.content_disposition.?);
    // Two full walks: the origin was re-requested, not skipped past.
    try std.testing.expectEqual(@as(usize, 2), hop1.requests);
    try std.testing.expectEqual(@as(usize, 2), hop2.requests);
}

test "a hop that fails once is classified rather than reported as a network failure" {
    // The classification walk feeds a download that retries the identical hop
    // three times. Surfacing the first blip here fails an install that the very
    // next step already knows how to survive.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    const cd = "attachment; filename=\"artifact.dmg\"";
    var hop1 = Hop{
        .io = io,
        .listener = &l1,
        .fail_first = true,
        .content_disposition = cd,
    };
    const t1 = try std.Thread.spawn(.{}, serveCount, .{ &hop1, 2 });

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    // One retry, no wall-clock: the subject is whether the walk retries at all.
    http.retry_backoff_ms = &.{0};

    const result = http.headResolved(url);
    http.deinit();
    knock(io, p1);
    t1.join();

    var resolved = try result;
    defer resolved.deinit();

    try std.testing.expectEqualStrings(url, resolved.final_url);
    try std.testing.expectEqualStrings(cd, resolved.content_disposition.?);
    try std.testing.expectEqual(@as(usize, 2), hop1.requests);
}

// Short enough that a green run costs nothing, long enough that the watchdog's
// 100 ms tick floor gets a couple of ticks before it fires.
const stall_budget_ns: u64 = 300 * std.time.ns_per_ms;

test "a classification walk gives up on an origin that never answers" {
    // The stall is the severity driver: `mt install <cask>` classifies under
    // `db/malt.lock`, so a parked head read blocks every other invocation too.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var hop1 = Hop{ .io = io, .listener = &l1, .stall = true };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/artifact", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.head_timeout_ns = stall_budget_ns;
    http.retry_backoff_ms = &.{};

    const result = http.headResolved(url);
    http.deinit();
    t1.join();

    try std.testing.expectError(error.HeadTimeout, result);
    try std.testing.expectEqual(@as(usize, 1), hop1.requests);
}

test "a download gives up on an origin that never answers" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var hop1 = Hop{ .io = io, .listener = &l1, .stall = true };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/blob", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.head_timeout_ns = stall_budget_ns;
    http.retry_backoff_ms = &.{};

    const result = http.getWithHeaders(url, &.{}, null, .transport_only);
    http.deinit();
    t1.join();

    try std.testing.expectError(error.HeadTimeout, result);
    try std.testing.expectEqual(@as(usize, 1), hop1.requests);
}

// The hop the probe below watches. Gating on a request the hop has actually
// received keeps the Ctrl-C inside the head-read window rather than collapsing
// the connect that precedes it.
var cancel_after_served: ?*const Hop = null;

fn cancelledOnceServed() bool {
    const hop = cancel_after_served orelse return false;
    return hop.served.load(.acquire) > 0;
}

test "Ctrl-C during a stalled head read is the answer, not a blip to retry" {
    // Without the cancel check the fix makes Ctrl-C slower: the watchdog's
    // socket shutdown looks like an ordinary transport fault, so the walk
    // would sleep off the whole backoff and re-dial while the flag stays set.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var hop1 = Hop{ .io = io, .listener = &l1, .stall = true };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});
    cancel_after_served = &hop1;
    defer cancel_after_served = null;

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/artifact", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.head_timeout_ns = stall_budget_ns;
    http.cancel = &cancelledOnceServed;
    // A budget the retry loop could spend if it treated the cancel as a blip.
    http.retry_backoff_ms = &.{ 0, 0, 0 };

    const result = http.headResolved(url);
    http.deinit();
    t1.join();

    try std.testing.expectError(error.Canceled, result);
    try std.testing.expectEqual(@as(usize, 1), hop1.requests);
}

test "a blob download gives up on an origin that never answers" {
    // `followGetToWriter` wires the deadline separately from the buffered
    // walk, so its own fixture is what proves that wiring exists.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var hop1 = Hop{ .io = io, .listener = &l1, .stall = true };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/bottle", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.head_timeout_ns = stall_budget_ns;
    http.retry_backoff_ms = &.{};

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const result = http.getToWriter(url, &.{}, &sink.writer, null);
    http.deinit();
    t1.join();

    try std.testing.expectError(error.HeadTimeout, result);
    try std.testing.expectEqual(@as(usize, 1), hop1.requests);
}

test "a bare HEAD gives up on an origin that never answers" {
    // `doctor`'s reachability probe is the caller here: a silent host used to
    // park the whole check with nothing on screen.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var hop1 = Hop{ .io = io, .listener = &l1, .stall = true };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/probe", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.head_timeout_ns = stall_budget_ns;

    const result = http.head(url);
    http.deinit();
    t1.join();

    try std.testing.expectError(error.HeadTimeout, result);
    try std.testing.expectEqual(@as(usize, 1), hop1.requests);
}

test "a silent peer is not re-dialled three more times" {
    // Silence for the whole budget is the peer's answer. Retrying it spends
    // the backoff for nothing while `db/malt.lock` stays held - the cost that
    // made the original hang severe in the first place.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var hop1 = Hop{ .io = io, .listener = &l1, .stall = true };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/artifact", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.head_timeout_ns = stall_budget_ns;
    // A full budget the walk would spend if it read the silence as a blip.
    http.retry_backoff_ms = &.{ 0, 0, 0 };

    const result = http.headResolved(url);
    http.deinit();
    t1.join();

    try std.testing.expectError(error.HeadTimeout, result);
    try std.testing.expectEqual(@as(usize, 1), hop1.requests);
}

test "a hop that answers refreshes the budget for the next one" {
    // Per hop, not per walk: a chain is not at fault for being long, and each
    // answering peer is fresh evidence of liveness. Both hops answer well
    // inside their own budget while together exceeding one, so a single clock
    // shared across the walk would cut the second hop off.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const budget_ns: u64 = 1000 * std.time.ns_per_ms;
    const per_hop_ns: u64 = 600 * std.time.ns_per_ms;

    var l2 = try bindIp4(io);
    defer l2.deinit(io);
    const p2 = l2.socket.address.getPort();
    var hop2 = Hop{ .io = io, .listener = &l2, .answer_delay_ns = per_hop_ns };
    const t2 = try std.Thread.spawn(.{}, serveOne, .{&hop2});

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/artifact", .{p2});

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();
    var hop1 = Hop{
        .io = io,
        .listener = &l1,
        .redirect_to = loc,
        .status = .found,
        .answer_delay_ns = per_hop_ns,
    };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.head_timeout_ns = budget_ns;
    http.retry_backoff_ms = &.{};

    const result = http.headResolved(url);
    http.deinit();
    t1.join();
    t2.join();

    var resolved = try result;
    defer resolved.deinit();
    try std.testing.expectEqualStrings(loc, resolved.final_url);
}

// Long enough that the connect is observably cut, short enough that a green
// run costs nothing.
const tls_silent_budget_ns: u64 = 500 * std.time.ns_per_ms;

test "a bare HEAD gives up on a peer that never starts its TLS handshake" {
    // Connect runs DNS, TCP and the whole TLS handshake before the head
    // watchdog has a connection to shut down, so this window had no deadline
    // at all - and `mt install` holds `db/malt.lock` across it.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var tls_silent = TlsSilentPeer{ .io = io, .listener = &l1 };
    const t1 = try std.Thread.spawn(.{}, acceptAndSayNothing, .{&tls_silent});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/probe", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.head_timeout_ns = tls_silent_budget_ns;

    const result = http.head(url);
    http.deinit();
    t1.join();

    try std.testing.expectError(error.HeadTimeout, result);
    try std.testing.expectEqual(@as(usize, 1), tls_silent.accepts.load(.acquire));
}

test "a download gives up on a peer that never starts its TLS handshake" {
    // `followGet` opens its own connection, so the buffered walk needs its own
    // fixture to prove the deadline is wired there too.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var tls_silent = TlsSilentPeer{ .io = io, .listener = &l1 };
    const t1 = try std.Thread.spawn(.{}, acceptAndSayNothing, .{&tls_silent});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/blob", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.head_timeout_ns = tls_silent_budget_ns;
    http.retry_backoff_ms = &.{};

    const result = http.getWithHeaders(url, &.{}, null, .transport_only);
    http.deinit();
    t1.join();

    try std.testing.expectError(error.HeadTimeout, result);
    try std.testing.expectEqual(@as(usize, 1), tls_silent.accepts.load(.acquire));
}

test "a blob stream gives up on a peer that never starts its TLS handshake" {
    // `followGetToWriter` wires its deadline separately from the buffered walk.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var tls_silent = TlsSilentPeer{ .io = io, .listener = &l1 };
    const t1 = try std.Thread.spawn(.{}, acceptAndSayNothing, .{&tls_silent});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/bottle", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.head_timeout_ns = tls_silent_budget_ns;
    http.retry_backoff_ms = &.{};

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const result = http.getToWriter(url, &.{}, &sink.writer, null);
    http.deinit();
    t1.join();

    try std.testing.expectError(error.HeadTimeout, result);
    try std.testing.expectEqual(@as(usize, 1), tls_silent.accepts.load(.acquire));
}

// The peer the cancel probe below watches. A Ctrl-C only counts once the
// connection exists, so the assertion is about the handshake window rather
// than a race with the dial.
var cancel_watch: ?*const TlsSilentPeer = null;

fn cancelledOnceAccepted() bool {
    const peer = cancel_watch orelse return false;
    return peer.accepts.load(.acquire) > 0;
}

test "Ctrl-C during a stalled TLS handshake is the answer, not a blip to retry" {
    // Nothing sampled the cancel flag inside the handshake, so a Ctrl-C waited
    // out the full budget - and, read as an ordinary transport fault, was then
    // slept off and re-dialled.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();

    var tls_silent = TlsSilentPeer{ .io = io, .listener = &l1 };
    const t1 = try std.Thread.spawn(.{}, acceptAndSayNothing, .{&tls_silent});
    cancel_watch = &tls_silent;
    defer cancel_watch = null;

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/artifact", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    // A budget far past the point of the test: only the cancel can end this.
    http.head_timeout_ns = 60 * std.time.ns_per_s;
    http.cancel = &cancelledOnceAccepted;
    // A budget the retry loop could spend if it read the cancel as a blip.
    http.retry_backoff_ms = &.{ 0, 0, 0 };

    const result = http.headResolved(url);
    http.deinit();
    t1.join();

    try std.testing.expectError(error.Canceled, result);
    try std.testing.expectEqual(@as(usize, 1), tls_silent.accepts.load(.acquire));
}

test "an unframed redirect is released without draining until the peer closes" {
    // The 3xx body is never read and the stdlib release drains it; with no
    // framing headers that drain ends only when the peer closes, and no
    // watchdog runs across a redirect hop.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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
    var peer = UnframedRedirectPeer{ .io = io, .listener = &l1, .location = loc };
    const t1 = try std.Thread.spawn(.{}, serveUnframedRedirect, .{&peer});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.retry_backoff_ms = &.{};

    const started_ns: i128 = std.Io.Clock.real.now(io).toNanoseconds();
    const result = http.get(url);
    const elapsed_ms: i64 = @intCast(@divTrunc(
        std.Io.Clock.real.now(io).toNanoseconds() - started_ns,
        std.time.ns_per_ms,
    ));
    http.deinit();
    t1.join();
    t2.join();

    var resp = try result;
    defer resp.deinit();
    try std.testing.expectEqualStrings(blob_body, resp.body);
    try std.testing.expect(elapsed_ms < drain_budget_ms);
}

test "a streamed walk releases an unframed redirect without draining it" {
    // `followGetToWriter` releases its hops on its own code path.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l2 = try bindIp4(io);
    defer l2.deinit(io);
    const p2 = l2.socket.address.getPort();
    var hop2 = Hop{ .io = io, .listener = &l2 };
    const t2 = try std.Thread.spawn(.{}, serveOne, .{&hop2});

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://127.0.0.1:{d}/bottle", .{p2});

    var l1 = try bindIp4(io);
    defer l1.deinit(io);
    const p1 = l1.socket.address.getPort();
    var peer = UnframedRedirectPeer{ .io = io, .listener = &l1, .location = loc };
    const t1 = try std.Thread.spawn(.{}, serveUnframedRedirect, .{&peer});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.retry_backoff_ms = &.{};

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const started_ns: i128 = std.Io.Clock.real.now(io).toNanoseconds();
    const result = http.getToWriter(url, &.{}, &sink.writer, null);
    const elapsed_ms: i64 = @intCast(@divTrunc(
        std.Io.Clock.real.now(io).toNanoseconds() - started_ns,
        std.time.ns_per_ms,
    ));
    http.deinit();
    t1.join();
    t2.join();

    try std.testing.expectEqual(@as(u16, 200), try result);
    try std.testing.expectEqualStrings(blob_body, sink.written());
    try std.testing.expect(elapsed_ms < drain_budget_ms);
}

test "a framed redirect still drains, so its connection stays poolable" {
    // Only the unframed case skips the drain. A 302 that declares its body
    // costs a cheap read, and retiring that connection would pay for a fresh
    // handshake on every hop of a healthy chain.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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
    // `Hop` answers a 302 with a declared body.
    var hop1 = Hop{ .io = io, .listener = &l1, .redirect_to = loc, .status = .found };
    const t1 = try std.Thread.spawn(.{}, serveOne, .{&hop1});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/start", .{p1});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    http.retry_backoff_ms = &.{};

    const result = http.get(url);
    http.deinit();
    t1.join();
    t2.join();

    var resp = try result;
    defer resp.deinit();
    try std.testing.expectEqualStrings(blob_body, resp.body);
}
