//! malt — offline integration for root-layout tap resolution.
//!
//! Inline tests in `src/core/forge.zig` cover the `.formula_root` URL
//! shape in isolation; this file pins the *assembled probe sequence*
//! `installTapRb` runs against a localhost `std.http.Server`, never live
//! network. raw_base in production is https-only (built in
//! `buildBaseUrls`), so the full `installTapRb` wiring is proven by the
//! `scripts/regressions/tap-root-layout-resolve-*.sh` field test; here we
//! drive the same forge seam (`rawFileUrl` + `getRawFile`) the probe loop
//! uses, against a server that models a root-layout tap: `Formula/` and
//! `Casks/` 404, the bare root `<name>.rb` 200s.
//!
//! It proves the fix's contract: a Formula/ + Casks/ double-404 falls
//! back to the no-subdir root `.rb` and resolves — the URL the old probe
//! chain never built.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const client = malt.client;
const tap = malt.tap;
const forge = malt.forge;
const net = std.Io.net;

const fixture_sha = "0123456789abcdef0123456789abcdef01234567";
const root_body = "class Yabai < Formula\n  url \"https://example.com/yabai.tar.gz\"\nend\n";

const Fixture = struct {
    io: std.Io,
    listener: *net.Server,
    root_body: []const u8,
    // Number of probe requests to serve before the thread returns.
    expected: usize,
};

// Serves `fx.expected` requests, routing by target: any `/Formula/` or
// `/Casks/` path 404s (the subtrees a root-layout tap lacks); everything
// else 200s with the root body. `keep_alive = false` closes each
// connection so the pooled client reconnects and `accept` fires per probe.
// Errors are swallowed: a failed serve surfaces as a client-side
// assertion failure in the test thread.
fn serveProbes(fx: *Fixture) void {
    var served: usize = 0;
    while (served < fx.expected) : (served += 1) {
        const stream = fx.listener.accept(fx.io) catch return;
        defer stream.close(fx.io);
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(fx.io, &rbuf);
        var writer = stream.writer(fx.io, &wbuf);
        var srv = std.http.Server.init(&reader.interface, &writer.interface);
        var req = srv.receiveHead() catch return;
        const target = req.head.target;
        const is_subdir = std.mem.indexOf(u8, target, "/Formula/") != null or
            std.mem.indexOf(u8, target, "/Casks/") != null;
        if (is_subdir) {
            req.respond("not found\n", .{ .status = .not_found, .keep_alive = false }) catch return;
        } else {
            req.respond(fx.root_body, .{ .keep_alive = false }) catch return;
        }
    }
}

fn listenLocal(io: std.Io) !net.Server {
    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    return addr.listen(io, .{ .reuse_address = true });
}

test "tap probe selection: Formula/ + Casks/ double-404 falls back to the root-layout .rb" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try listenLocal(io);
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var fx = Fixture{ .io = io, .listener = &listener, .root_body = root_body, .expected = 3 };
    const server_thread = try std.Thread.spawn(.{}, serveProbes, .{&fx});
    defer server_thread.join();

    var base_buf: [64]u8 = undefined;
    const raw_base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, .empty, testing.allocator);
    defer http.deinit();

    var url_buf: [256]u8 = undefined;

    // Probe 1 — Formula/ : the modern layout, absent here → 404.
    const formula_url = try forge.rawFileUrl(&url_buf, .github, raw_base, fixture_sha, .formula, "yabai");
    var formula_resp = try tap.getRawFile(&http, .empty, .github, formula_url);
    defer formula_resp.deinit();
    try testing.expectEqual(@as(u16, 404), formula_resp.status);

    // Probe 2 — Casks/ : also absent → 404. Pre-fix the resolver gave up here.
    const cask_url = try forge.rawFileUrl(&url_buf, .github, raw_base, fixture_sha, .cask, "yabai");
    var cask_resp = try tap.getRawFile(&http, .empty, .github, cask_url);
    defer cask_resp.deinit();
    try testing.expectEqual(@as(u16, 404), cask_resp.status);

    // Probe 3 — root `<name>.rb` : the added fallback resolves the formula.
    const root_url = try forge.rawFileUrl(&url_buf, .github, raw_base, fixture_sha, .formula_root, "yabai");
    var root_resp = try tap.getRawFile(&http, .empty, .github, root_url);
    defer root_resp.deinit();
    try testing.expectEqual(@as(u16, 200), root_resp.status);
    try testing.expectEqualStrings(root_body, root_resp.body);

    // The resolving URL is the no-subdir root tail — the URL the old
    // two-probe chain never built.
    var exp_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&exp_buf, "http://127.0.0.1:{d}/{s}/yabai.rb", .{ port, fixture_sha });
    try testing.expectEqualStrings(expected, root_url);
}
