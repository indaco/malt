//! malt — offline integration for forge-aware `mt tap --pin`.
//!
//! `mt tap --pin <slug> <sha>` proves a SHA is reachable before storing
//! it. Inline tests in `src/core/forge.zig` cover the `commits/<sha>` URL
//! and SHA-parse shapes per forge; `src/core/tap.zig` covers that
//! `resolveCommitUrl` builds the forge-correct URL off the row. This file
//! pins the assembled HTTP path against **recorded** `commits/<sha>`
//! bodies (`scripts/fixtures/`), never live network, proving the pin
//! check resolves correctly when driven with the tap's own forge:
//!   1. a GitLab `{"id":"<sha>"}` body resolves to the pinned sha;
//!   2. a Codeberg `{"sha":"<sha>"}` single **object** (not the `?limit=1`
//!      array its HEAD path uses) resolves too — the pin path's distinct
//!      response shape;
//!   3. a malformed/absent commit fails loud (MalformedJson / NotFound),
//!      so a bad SHA can never land as a pin;
//!   4. driving a GitLab body with the *github* parser rejects it — the
//!      reason the pin must carry the row's forge, not a `.github` literal.

const std = @import("std");
const testing = std.testing;
const test_io = @import("test_io");

const malt = @import("malt");
const tap = malt.tap;
const net = std.Io.net;

// The sha recorded in both forge `commits/<sha>` fixtures.
const fixture_sha = "0123456789abcdef0123456789abcdef01234567";

fn readFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const io = std.Options.debug_io;
    var dir = try test_io.cwd().openDir(io, "scripts/fixtures", .{});
    defer dir.close(io);
    const file = try dir.openFile(io, name, .{});
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
    status: std.http.Status = .ok,
};

// Serves one request with `fx.body` at `fx.status`. Errors are swallowed:
// a failed serve surfaces as a client-side assertion failure in the test.
fn serveOnce(fx: *Fixture) void {
    const stream = fx.listener.accept(fx.io) catch return;
    defer stream.close(fx.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(fx.io, &rbuf);
    var writer = stream.writer(fx.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    var req = srv.receiveHead() catch return;
    req.respond(fx.body, .{ .status = fx.status }) catch return;
}

fn listenLocal(io: std.Io) !net.Server {
    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    return addr.listen(io, .{ .reuse_address = true });
}

// Resolve a `commits/<sha>` body served on localhost with the given forge.
// Mirrors the shape pinTap drives: the row's forge selects the parser.
fn resolveServed(
    forge_kind: malt.forge.Forge,
    body: []const u8,
    status: std.http.Status,
) !tap.HeadResolution {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try listenLocal(io);
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var fx = Fixture{ .io = io, .listener = &listener, .body = body, .status = status };
    const server_thread = try std.Thread.spawn(.{}, serveOnce, .{&fx});
    defer server_thread.join();

    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/commits/{s}", .{ port, fixture_sha });
    return tap.resolveHeadCommit(io, .empty, testing.allocator, forge_kind, url, null);
}

test "gitlab pin: a recorded commits/<sha> body resolves to the pinned sha" {
    const body = try readFixture(testing.allocator, "gitlab_commits_head.json");
    defer testing.allocator.free(body);

    var res = try resolveServed(.gitlab, body, .ok);
    defer res.deinit();
    try testing.expect(!res.not_modified);
    try testing.expectEqualStrings(fixture_sha, res.sha.?);
}

test "gitea pin: a single commit object (not the HEAD array) resolves to the pinned sha" {
    const body = try readFixture(testing.allocator, "gitea_commit.json");
    defer testing.allocator.free(body);

    var res = try resolveServed(.gitea, body, .ok);
    defer res.deinit();
    try testing.expect(!res.not_modified);
    try testing.expectEqualStrings(fixture_sha, res.sha.?);
}

test "gitea pin: a 200 with no sha is rejected as MalformedJson — a bad pin never lands" {
    var res = resolveServed(.gitea, "{}", .ok) catch |e| {
        try testing.expectEqual(tap.TapError.MalformedJson, e);
        return;
    };
    res.deinit();
    return error.TestUnexpectedResult;
}

test "gitea pin: a 404 for an unknown sha fails loud with NotFound" {
    var res = resolveServed(.gitea, "", .not_found) catch |e| {
        try testing.expectEqual(tap.TapError.NotFound, e);
        return;
    };
    res.deinit();
    return error.TestUnexpectedResult;
}

test "gitlab pin: the github parser rejects the gitlab id-shaped body — the pin must carry the row forge" {
    // GitLab's commit object leads with `"id"`, not `"sha"`. Driving it
    // with `.github` (the old hard-coded literal) yields MalformedJson, so
    // pinTap must pass the row's effective forge for a gitlab pin to land.
    const body = try readFixture(testing.allocator, "gitlab_commits_head.json");
    defer testing.allocator.free(body);

    var res = resolveServed(.github, body, .ok) catch |e| {
        try testing.expectEqual(tap.TapError.MalformedJson, e);
        return;
    };
    res.deinit();
    return error.TestUnexpectedResult;
}
