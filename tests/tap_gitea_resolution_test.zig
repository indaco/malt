//! malt — offline integration for Gitea (Codeberg/Forgejo) tap resolution.
//!
//! Inline tests in `src/core/forge.zig` cover the URL/parse/auth shapes
//! in isolation; this file pins the assembled HTTP path against a
//! **recorded** Gitea `commits?limit=1` response (`scripts/fixtures/`),
//! never live network. It proves three things end-to-end for `.gitea`:
//!   1. a recorded `[{"sha":"<sha>"}]` array body resolves to the right
//!      sha, and that sha builds the right `/raw/.../Formula/<n>.rb` URL;
//!   2. the API request carries `Authorization: token` when
//!      MALT_GITEA_TOKEN is set;
//!   3. the raw fetch also carries it — Gitea serves `/raw` from the
//!      authenticated instance host, unlike github's public raw CDN.

const std = @import("std");
const testing = std.testing;
const net = std.Io.net;

const malt = @import("malt");
const client = malt.client;
const tap = malt.tap;
const forge = malt.forge;
const test_io = @import("test_io");

// The sha recorded in scripts/fixtures/gitea_commits_head.json.
const fixture_sha = "0123456789abcdef0123456789abcdef01234567";
const raw_body = "class Glow < Formula\nend\n";

fn readFixture(allocator: std.mem.Allocator) ![]u8 {
    const io = std.Options.debug_io;
    var dir = try test_io.cwd().openDir(io, "scripts/fixtures", .{});
    defer dir.close(io);
    const file = try dir.openFile(io, "gitea_commits_head.json", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

const Fixture = struct {
    io: std.Io,
    listener: *net.Server,
    body: []const u8,
    // Captured `Authorization` value, if the request carried one.
    authorization: [128]u8 = undefined,
    authorization_len: usize = 0,
};

// Serves one request, recording the request's Authorization header (if
// any) before responding with `fx.body`. Errors are swallowed: a failed
// serve surfaces as a client-side assertion failure in the test thread.
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
        if (std.ascii.eqlIgnoreCase(h.name, "authorization") and h.value.len <= fx.authorization.len) {
            @memcpy(fx.authorization[0..h.value.len], h.value);
            fx.authorization_len = h.value.len;
        }
    }
    req.respond(fx.body, .{}) catch return;
}

fn envWithGiteaToken() std.process.Environ {
    const entries = [_:null]?[*:0]const u8{"MALT_GITEA_TOKEN=cb-itest"};
    return .{ .block = .{ .slice = entries[0..1 :null] } };
}

fn listenLocal(io: std.Io) !net.Server {
    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    return addr.listen(io, .{ .reuse_address = true });
}

test "gitea resolve: a recorded commits array body yields the sha and its raw .rb URL" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const body = try readFixture(testing.allocator);
    defer testing.allocator.free(body);

    var listener = try listenLocal(io);
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var fx = Fixture{ .io = io, .listener = &listener, .body = body };
    const server_thread = try std.Thread.spawn(.{}, serveOnce, .{&fx});
    defer server_thread.join();

    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/repos/grp/tap/commits?limit=1&stat=false", .{port});

    var res = try tap.resolveHeadCommit(io, .empty, testing.allocator, .gitea, url, null);
    defer res.deinit();
    try testing.expect(!res.not_modified);
    try testing.expectEqualStrings(fixture_sha, res.sha.?);

    // The resolved sha builds the forge-correct raw `.rb` URL — the other
    // half of criterion: registering + resolving yields the right raw URL.
    var raw_buf: [256]u8 = undefined;
    const raw_url = try forge.rawFileUrl(
        &raw_buf,
        .gitea,
        "https://codeberg.org/grp/tap/raw",
        res.sha.?,
        .formula,
        "glow",
    );
    try testing.expectEqualStrings(
        "https://codeberg.org/grp/tap/raw/" ++ fixture_sha ++ "/Formula/glow.rb",
        raw_url,
    );
}

test "gitea resolve: the API request carries Authorization token when MALT_GITEA_TOKEN is set" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const body = try readFixture(testing.allocator);
    defer testing.allocator.free(body);

    var listener = try listenLocal(io);
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var fx = Fixture{ .io = io, .listener = &listener, .body = body };
    const server_thread = try std.Thread.spawn(.{}, serveOnce, .{&fx});
    defer server_thread.join();

    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/repos/grp/tap/commits?limit=1&stat=false", .{port});

    var res = try tap.resolveHeadCommit(io, envWithGiteaToken(), testing.allocator, .gitea, url, null);
    defer res.deinit();
    try testing.expectEqualStrings("token cb-itest", fx.authorization[0..fx.authorization_len]);
}

test "gitea raw fetch: getRawFile carries Authorization token — raw lives on the instance host" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try listenLocal(io);
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var fx = Fixture{ .io = io, .listener = &listener, .body = raw_body };
    const server_thread = try std.Thread.spawn(.{}, serveOnce, .{&fx});
    defer server_thread.join();

    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/grp/tap/raw/{s}/Formula/glow.rb", .{ port, fixture_sha });

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, envWithGiteaToken(), testing.allocator);
    defer http.deinit();

    var resp = try tap.getRawFile(&http, envWithGiteaToken(), .gitea, url);
    defer resp.deinit();
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings(raw_body, resp.body);
    try testing.expectEqualStrings("token cb-itest", fx.authorization[0..fx.authorization_len]);
}
