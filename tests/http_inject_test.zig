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

const AuthFixture = struct {
    io: std.Io,
    listener: *net.Server,
    saw_auth: bool = false,
};

// Like serveOnce, but records whether the request carried an Authorization
// header. Read `saw_auth` only after joining the server thread.
fn serveOnceRecordingAuth(fx: *AuthFixture) void {
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

test "HttpClient.get token resolution honors MALT_GITHUB_TOKEN, falls back to HOMEBREW_GITHUB_API_TOKEN" {
    // Self-update / notifier GETs go through HttpClient.get, whose auth must
    // honor the project's primary token. The loopback host gate
    // (githubTokenApplies) only fires on real GitHub hosts, so this asserts the
    // env-var selection directly — the wire-side header path is covered by the
    // round-trip test above and net_redirect_auth_test.
    {
        const entries = [_:null]?[*:0]const u8{
            "MALT_GITHUB_TOKEN=malt-tok".ptr,
            "HOMEBREW_GITHUB_API_TOKEN=brew-tok".ptr,
        };
        const env: std.process.Environ = .{ .block = .{ .slice = &entries } };
        try std.testing.expectEqualStrings("malt-tok", client.HttpClient.githubApiToken(env).?);
    }
    {
        // Empty MALT_GITHUB_TOKEN must not shadow a real Homebrew token.
        const entries = [_:null]?[*:0]const u8{
            "MALT_GITHUB_TOKEN=".ptr,
            "HOMEBREW_GITHUB_API_TOKEN=brew-tok".ptr,
        };
        const env: std.process.Environ = .{ .block = .{ .slice = &entries } };
        try std.testing.expectEqualStrings("brew-tok", client.HttpClient.githubApiToken(env).?);
    }
}

test "HttpClient.get does not leak the GitHub token to a non-GitHub host (cross-forge guarantee)" {
    // Even with MALT_GITHUB_TOKEN set, get() must not auto-inject Authorization
    // on a non-github host. A loopback host is non-github, so it stands in for
    // any other-forge host (gitlab.com, codeberg.org, a self-hosted Forgejo):
    // githubTokenApplies rejects them all identically. This proves the gate's
    // decision reaches the wire — those forges authenticate only via their own
    // MALT_GITLAB_TOKEN / MALT_GITEA_TOKEN through the forge seam, never here.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var fx = AuthFixture{ .io = io, .listener = &listener };
    const server_thread = try std.Thread.spawn(.{}, serveOnceRecordingAuth, .{&fx});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/releases/latest", .{port});

    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=ghp_must_not_leak".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = &entries } };

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, env, std.testing.allocator);
    defer http.deinit();

    // Join before reading server-side state so the assertion can't race the serve.
    const result = http.get(url);
    server_thread.join();

    var resp = try result;
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(!fx.saw_auth);
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
