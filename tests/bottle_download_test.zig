//! malt — `bottle.download` streaming integration tests.
//!
//! Drives the whole download path against a loopback `std.http.Server` that
//! answers `/token` and `/blobs/…` (the same offline transport the other net
//! tests use), so the create-temp → stream+hash → compare → extract pipeline
//! is exercised end to end with no real network.
//!
//! These pin the invariants the streaming rewrite must preserve: a verified
//! bottle extracts and the temp file is dropped; a SHA mismatch populates
//! `MismatchInfo` and wipes the temp + dest without ever extracting; a
//! mid-stream transport failure leaves nothing behind; and the digest is taken
//! over the stored (identity-encoded) `.tar.gz` bytes, matching Homebrew.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const bottle = malt.bottle;
const client = malt.client;
const ghcr = malt.ghcr;
const net = std.Io.net;

const Stub = struct {
    io: std.Io,
    listener: *net.Server,
    body: []const u8,
    // When true the blob GET sends a short chunk then drops the connection
    // without the terminating chunk, so the client's body read fails mid-200.
    truncate: bool = false,
    // When set, the blob 200 carries this `Content-Encoding` so the client
    // decodes `body` before the tee sees it (exercises the SHA domain).
    content_encoding: ?[]const u8 = null,
};

fn serveStub(s: *Stub) void {
    const stream = s.listener.accept(s.io) catch return;
    defer stream.close(s.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(s.io, &rbuf);
    var writer = stream.writer(s.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var req = srv.receiveHead() catch return;
        const target = req.head.target;
        if (std.mem.indexOf(u8, target, "/token") != null) {
            req.respond("{\"token\":\"t1\"}", .{}) catch return;
        } else if (std.mem.indexOf(u8, target, "/blobs/") != null) {
            if (s.truncate) {
                var body_buf: [64]u8 = undefined;
                var bw = req.respondStreaming(&body_buf, .{}) catch return;
                bw.writer.writeAll("partial") catch return;
                bw.flush() catch return;
                return; // drop the socket before the terminating chunk
            }
            const extra: []const std.http.Header = if (s.content_encoding) |enc|
                &.{.{ .name = "content-encoding", .value = enc }}
            else
                &.{};
            req.respond(s.body, .{ .extra_headers = extra }) catch return;
        } else {
            req.respond("not found\n", .{ .status = .not_found }) catch return;
        }
    }
}

// Real `Threaded` io to spawn `tar` — `std.Options.debug_io`'s failing
// allocator can't back a child spawn. Mints a valid bottle fixture.
fn runTar(argv: []const []const u8) !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{ .environ = malt.app_ctx.processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .ignore, .stderr = .ignore });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.TarFailed,
        else => return error.TarFailed,
    }
}

fn uniqueBase(suffix: []const u8) ![]const u8 {
    return test_io.uniqueTempPath(testing.allocator, "bottle_dl", suffix);
}

fn hexSha(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

// gzip-compress `raw` into `out`, returning the wire bytes (same primitive the
// archive tests use to mint fixtures).
fn gzipInto(out: []u8, raw: []const u8) ![]const u8 {
    var out_w = std.Io.Writer.fixed(out);
    var win: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&out_w, &win, .gzip, std.compress.flate.Compress.Options.level_4);
    try comp.writer.writeAll(raw);
    try comp.finish();
    return out_w.buffered();
}

fn pathExists(io: std.Io, path: []const u8) bool {
    test_io.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

test "download streams a verified bottle to disk, extracts it, and drops the temp file" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = try uniqueBase("ok");
    defer testing.allocator.free(base);
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.cwd().createDirPath(io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    // Mint a real gzip tarball: payload/hello.txt.
    const payload_dir = try std.fmt.allocPrint(testing.allocator, "{s}/work/payload", .{base});
    defer testing.allocator.free(payload_dir);
    try test_io.cwd().createDirPath(io, payload_dir);
    const hello = try std.fmt.allocPrint(testing.allocator, "{s}/hello.txt", .{payload_dir});
    defer testing.allocator.free(hello);
    {
        const f = try test_io.createFileAbsolute(io, hello, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "bottle payload\n");
    }
    const work = try std.fmt.allocPrint(testing.allocator, "{s}/work", .{base});
    defer testing.allocator.free(work);
    const archive_path = try std.fmt.allocPrint(testing.allocator, "{s}/bottle-fixture.tar.gz", .{base});
    defer testing.allocator.free(archive_path);
    try runTar(&.{ "tar", "czf", archive_path, "-C", work, "payload" });

    const body = try test_io.readFileAbsoluteAlloc(io, testing.allocator, archive_path, 1 << 20);
    defer testing.allocator.free(body);
    const sha = hexSha(body);

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    var stub = Stub{ .io = io, .listener = &listener, .body = body };
    const server_thread = try std.Thread.spawn(.{}, serveStub, .{&stub});

    var base_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);

    var g = ghcr.GhcrClient.init(io, testing.allocator, &http);
    defer g.deinit();
    g.base_url = base_url;

    const dest_dir = try std.fmt.allocPrint(testing.allocator, "{s}/dest", .{base});
    defer testing.allocator.free(dest_dir);

    var mismatch: bottle.MismatchInfo = undefined;
    const result = bottle.download(io, testing.allocator, &g, &http, "homebrew/core/pkg", "sha256:abc", &sha, dest_dir, null, &mismatch);

    http.deinit();
    server_thread.join();

    _ = try result;

    // Extracted content is present; the temp archive was removed.
    const extracted = try std.fmt.allocPrint(testing.allocator, "{s}/payload/hello.txt", .{dest_dir});
    defer testing.allocator.free(extracted);
    try testing.expect(pathExists(io, extracted));
    const tmp_archive = try std.fmt.allocPrint(testing.allocator, "{s}/bottle.tar.gz", .{dest_dir});
    defer testing.allocator.free(tmp_archive);
    try testing.expect(!pathExists(io, tmp_archive));
}

test "download rejects a SHA mismatch: populates MismatchInfo, wipes temp + dest, never extracts" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = try uniqueBase("mismatch");
    defer testing.allocator.free(base);
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.cwd().createDirPath(io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    // Any bytes will do — the bottle is never extracted on a mismatch.
    const blob = "these-identity-encoded-bytes-are-not-a-real-bottle-0123456789";
    const real = hexSha(blob);
    const wrong = "0" ** 64;

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    var stub = Stub{ .io = io, .listener = &listener, .body = blob };
    const server_thread = try std.Thread.spawn(.{}, serveStub, .{&stub});

    var base_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);

    var g = ghcr.GhcrClient.init(io, testing.allocator, &http);
    defer g.deinit();
    g.base_url = base_url;

    const dest_dir = try std.fmt.allocPrint(testing.allocator, "{s}/dest", .{base});
    defer testing.allocator.free(dest_dir);

    var mismatch: bottle.MismatchInfo = undefined;
    const result = bottle.download(io, testing.allocator, &g, &http, "homebrew/core/pkg", "sha256:abc", wrong, dest_dir, null, &mismatch);

    http.deinit();
    server_thread.join();

    try testing.expectError(bottle.BottleError.Sha256Mismatch, result);
    // body_len comes from the tee, and computed is the SHA of exactly the
    // served identity bytes — pinning the SHA domain to the stored .tar.gz,
    // not a re-inflated stream.
    try testing.expectEqual(@as(u64, blob.len), mismatch.body_len);
    try testing.expectEqualStrings(&real, &mismatch.computed);
    try testing.expectEqualStrings(wrong, mismatch.expected[0..64]);
    // The whole dest dir (temp archive included) is gone — nothing extracted.
    try testing.expect(!pathExists(io, dest_dir));
}

test "a verified-but-unextractable archive fails closed: ExtractionFailed wipes the dest dir" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = try uniqueBase("extractfail");
    defer testing.allocator.free(base);
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.cwd().createDirPath(io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    // A body that passes its SHA check but is not a gzip archive: extraction
    // rejects it on the magic-byte sniff. The SHA is over these exact bytes.
    const blob = "definitely-not-a-gzip-archive-but-its-own-valid-sha256";
    const sha = hexSha(blob);

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    var stub = Stub{ .io = io, .listener = &listener, .body = blob };
    const server_thread = try std.Thread.spawn(.{}, serveStub, .{&stub});

    var base_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);

    var g = ghcr.GhcrClient.init(io, testing.allocator, &http);
    defer g.deinit();
    g.base_url = base_url;

    const dest_dir = try std.fmt.allocPrint(testing.allocator, "{s}/dest", .{base});
    defer testing.allocator.free(dest_dir);

    var mismatch: bottle.MismatchInfo = undefined;
    const result = bottle.download(io, testing.allocator, &g, &http, "homebrew/core/pkg", "sha256:abc", &sha, dest_dir, null, &mismatch);

    http.deinit();
    server_thread.join();

    // SHA matched, so this is not a mismatch — extraction is what fails, and
    // the errdefer still wipes the dest dir (and the temp archive with it).
    try testing.expectError(bottle.BottleError.ExtractionFailed, result);
    try testing.expect(!pathExists(io, dest_dir));
}

test "the tee hashes the transport-decoded bottle, not the wire bytes (SHA domain under gzip)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = try uniqueBase("gzipdomain");
    defer testing.allocator.free(base);
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.cwd().createDirPath(io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    // The bytes Homebrew signs are the decoded .tar.gz; here the transport adds
    // a gzip Content-Encoding on top, which the client strips before the tee.
    const decoded = "the-decoded-bottle-bytes-that-homebrew-actually-hashes-0123456789";
    var wire_buf: [512]u8 = undefined;
    const wire = try gzipInto(&wire_buf, decoded);

    const decoded_sha = hexSha(decoded);
    const wire_sha = hexSha(wire);
    // The two domains must differ, or the assertion below proves nothing.
    try testing.expect(!std.mem.eql(u8, &decoded_sha, &wire_sha));

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    var stub = Stub{ .io = io, .listener = &listener, .body = wire, .content_encoding = "gzip" };
    const server_thread = try std.Thread.spawn(.{}, serveStub, .{&stub});

    var base_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);

    var g = ghcr.GhcrClient.init(io, testing.allocator, &http);
    defer g.deinit();
    g.base_url = base_url;

    const dest_dir = try std.fmt.allocPrint(testing.allocator, "{s}/dest", .{base});
    defer testing.allocator.free(dest_dir);

    const wrong = "0" ** 64;
    var mismatch: bottle.MismatchInfo = undefined;
    const result = bottle.download(io, testing.allocator, &g, &http, "homebrew/core/pkg", "sha256:abc", wrong, dest_dir, null, &mismatch);

    http.deinit();
    server_thread.join();

    try testing.expectError(bottle.BottleError.Sha256Mismatch, result);
    // computed is the SHA of the decoded bytes (what Homebrew signs), never the
    // gzip wire; body_len is the decoded length, not the compressed one.
    try testing.expectEqualStrings(&decoded_sha, &mismatch.computed);
    try testing.expectEqual(@as(u64, decoded.len), mismatch.body_len);
}

test "a mid-stream transport failure leaves no temp file and no dest dir" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = try uniqueBase("truncated");
    defer testing.allocator.free(base);
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.cwd().createDirPath(io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    var stub = Stub{ .io = io, .listener = &listener, .body = "unused", .truncate = true };
    const server_thread = try std.Thread.spawn(.{}, serveStub, .{&stub});

    var base_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);

    var g = ghcr.GhcrClient.init(io, testing.allocator, &http);
    defer g.deinit();
    g.base_url = base_url;

    const dest_dir = try std.fmt.allocPrint(testing.allocator, "{s}/dest", .{base});
    defer testing.allocator.free(dest_dir);

    var mismatch: bottle.MismatchInfo = undefined;
    const result = bottle.download(io, testing.allocator, &g, &http, "homebrew/core/pkg", "sha256:abc", "0" ** 64, dest_dir, null, &mismatch);

    http.deinit();
    server_thread.join();

    // A partial 200 became a transport error; the partial .tar.gz and the dest
    // dir were both cleaned up (the same errdefer path an over-cap stream takes).
    try testing.expectError(bottle.BottleError.DownloadFailed, result);
    try testing.expect(!pathExists(io, dest_dir));
}
