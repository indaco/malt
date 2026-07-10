//! malt — GHCR blob 401 invalidate-and-retry integration test.
//! Stands up a localhost `std.http.Server` that answers `/token` and
//! `/blobs/…`, and drives `GhcrClient.downloadBlob` against it. A blob
//! GET that 401s on a locally-unexpired token must invalidate the cache,
//! re-fetch a fresh token, and replay the GET exactly once — the contract
//! the doc-comment promises. No real network: the stub is loopback.

const std = @import("std");
const client = @import("malt").client;
const ghcr = @import("malt").ghcr;
const net = std.Io.net;

const blob_body = "BOTTLE-BYTES";

const Stub = struct {
    io: std.Io,
    listener: *net.Server,
    // When true every blob GET answers 401 (terminal-second-401 case);
    // otherwise the first blob GET 401s and later ones succeed.
    always_401: bool = false,
    // When set, every blob GET answers this status (used to prove a non-401
    // error is NOT treated as the skew/revocation retry case).
    force_status: ?std.http.Status = null,
    token_count: usize = 0,
    blob_count: usize = 0,
    // Bearer value presented on each blob GET, copied out of the per-request
    // buffer so the test can compare token#1 vs token#2 after the join.
    blob_auth: [2][256]u8 = undefined,
    blob_auth_len: [2]usize = .{ 0, 0 },
};

// Serves the whole token→blob→token→blob sequence on one keep-alive
// connection. Loops until the client closes (via `http.deinit`), which
// surfaces as a `receiveHead` error and ends the thread cleanly whether the
// download succeeded, retried, or bailed on the first 401.
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
            s.token_count += 1;
            var body_buf: [64]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"token\":\"t{d}\"}}", .{s.token_count}) catch return;
            req.respond(body, .{}) catch return;
        } else if (std.mem.indexOf(u8, target, "/blobs/") != null) {
            const idx = @min(s.blob_count, s.blob_auth.len - 1);
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                    const n = @min(h.value.len, s.blob_auth[idx].len);
                    @memcpy(s.blob_auth[idx][0..n], h.value[0..n]);
                    s.blob_auth_len[idx] = n;
                }
            }
            s.blob_count += 1;
            if (s.force_status) |st| {
                req.respond("error\n", .{ .status = st }) catch return;
            } else if (s.always_401 or s.blob_count == 1) {
                req.respond("unauthorized\n", .{ .status = .unauthorized }) catch return;
            } else {
                req.respond(blob_body, .{}) catch return;
            }
        } else {
            req.respond("not found\n", .{ .status = .not_found }) catch return;
        }
    }
}

fn blobAuth(s: *const Stub, idx: usize) []const u8 {
    return s.blob_auth[idx][0..s.blob_auth_len[idx]];
}

test "downloadBlob invalidates the cached token and retries once on a 401" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener };
    const server_thread = try std.Thread.spawn(.{}, serveStub, .{&stub});

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var g = ghcr.GhcrClient.init(io, std.testing.allocator, &http);
    defer g.deinit();
    g.base_url = base;

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const result = g.downloadBlob(&http, "homebrew/core/tree", "sha256:abc", &sink.writer, null);

    // Close the client so the server's keep-alive loop ends, then join
    // before reading server-side counters to avoid a data race.
    http.deinit();
    server_thread.join();

    try result;
    try std.testing.expectEqualStrings(blob_body, sink.writer.buffered());
    // Two token fetches: the initial one plus the post-invalidation refresh.
    try std.testing.expectEqual(@as(usize, 2), stub.token_count);
    try std.testing.expectEqual(@as(usize, 2), stub.blob_count);
    // The retry must present a *fresh* bearer, not replay the rejected one.
    try std.testing.expect(!std.mem.eql(u8, blobAuth(&stub, 0), blobAuth(&stub, 1)));
}

test "downloadBlob returns Unauthorized after a second 401 (retry bounded to once)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener, .always_401 = true };
    const server_thread = try std.Thread.spawn(.{}, serveStub, .{&stub});

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var g = ghcr.GhcrClient.init(io, std.testing.allocator, &http);
    defer g.deinit();
    g.base_url = base;

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const result = g.downloadBlob(&http, "homebrew/core/tree", "sha256:abc", &sink.writer, null);

    http.deinit();
    server_thread.join();

    try std.testing.expectError(ghcr.GhcrError.Unauthorized, result);
    // Exactly one retry: two token fetches, two blob GETs — never a third.
    try std.testing.expectEqual(@as(usize, 2), stub.token_count);
    try std.testing.expectEqual(@as(usize, 2), stub.blob_count);
}

test "downloadBlob does not refresh the token on a non-401 error" {
    // Pins the retry boundary: only 401 is the skew/revocation case. A 403
    // must surface immediately with no cache invalidation and no re-fetch,
    // so a future edit can't silently widen the retry to every error.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener, .force_status = .forbidden };
    const server_thread = try std.Thread.spawn(.{}, serveStub, .{&stub});

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var g = ghcr.GhcrClient.init(io, std.testing.allocator, &http);
    defer g.deinit();
    g.base_url = base;

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const result = g.downloadBlob(&http, "homebrew/core/tree", "sha256:abc", &sink.writer, null);

    http.deinit();
    server_thread.join();

    try std.testing.expectError(ghcr.GhcrError.DownloadHttpClientError, result);
    // No refresh: the token was fetched once and the blob GET issued once.
    try std.testing.expectEqual(@as(usize, 1), stub.token_count);
    try std.testing.expectEqual(@as(usize, 1), stub.blob_count);
}

// Records every progress report so a test can inspect how the callback fires
// across the failed + retried attempts.
const ProgressRec = struct {
    calls: usize = 0,
    last_bytes: u64 = 0,
    // Distinct content-lengths seen: one report sequence per response body.
    lens: [8]u64 = undefined,
    len_count: usize = 0,

    fn record(ctx: *anyopaque, bytes_so_far: u64, content_length: ?u64) void {
        const self: *ProgressRec = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_bytes = bytes_so_far;
        const cl = content_length orelse return;
        for (self.lens[0..self.len_count]) |v| if (v == cl) return;
        if (self.len_count < self.lens.len) {
            self.lens[self.len_count] = cl;
            self.len_count += 1;
        }
    }
};

test "downloadBlob progress reports only the streamed blob, not the discarded 401 body" {
    // The streaming path drains every non-200 body (including the 401 we
    // re-auth on) into net's throwaway with no progress callback, so the
    // caller's progress only ever sees the definitive 200 blob. No reset, no
    // double-count across the failed + retried attempts — the old buffered
    // path's double-fire quirk is gone.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var stub = Stub{ .io = io, .listener = &listener };
    const server_thread = try std.Thread.spawn(.{}, serveStub, .{&stub});

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);

    var g = ghcr.GhcrClient.init(io, std.testing.allocator, &http);
    defer g.deinit();
    g.base_url = base;

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    var rec = ProgressRec{};
    const progress = client.ProgressCallback{ .context = &rec, .func = ProgressRec.record };
    const result = g.downloadBlob(&http, "homebrew/core/tree", "sha256:abc", &sink.writer, progress);

    http.deinit();
    server_thread.join();

    try result;
    try std.testing.expectEqualStrings(blob_body, sink.writer.buffered());
    // Exactly one content-length was reported: only the 200 blob streamed
    // through progress; the discarded 401 body never did.
    try std.testing.expectEqual(@as(usize, 1), rec.len_count);
    try std.testing.expect(rec.calls >= 1);
    // The final report reflects the real blob, not the discarded error body.
    try std.testing.expectEqual(@as(u64, blob_body.len), rec.last_bytes);
}

const ConcStub = struct {
    io: std.Io,
    listener: *net.Server,
    // Shared across both handler threads; atomic so the two workers' token
    // fetches can't race the increment.
    token_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn concToken(cs: *ConcStub) usize {
    return cs.token_count.fetchAdd(1, .monotonic) + 1;
}

// One connection carries one worker's token→blob(401)→token→blob(200) run;
// a per-connection blob counter gives each worker its own first-401.
fn serveConcConn(cs: *ConcStub, stream: net.Stream) void {
    defer stream.close(cs.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(cs.io, &rbuf);
    var writer = stream.writer(cs.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    var local_blob: usize = 0;
    while (true) {
        var req = srv.receiveHead() catch return;
        const target = req.head.target;
        if (std.mem.indexOf(u8, target, "/token") != null) {
            var body_buf: [64]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"token\":\"t{d}\"}}", .{concToken(cs)}) catch return;
            req.respond(body, .{}) catch return;
        } else if (std.mem.indexOf(u8, target, "/blobs/") != null) {
            local_blob += 1;
            if (local_blob == 1) {
                req.respond("unauthorized\n", .{ .status = .unauthorized }) catch return;
            } else {
                req.respond(blob_body, .{}) catch return;
            }
        } else {
            req.respond("not found\n", .{ .status = .not_found }) catch return;
        }
    }
}

// Serves the two worker connections concurrently, one handler thread each.
// Keep-alive means each worker reuses a single connection, so two accepts
// cover the whole run; handlers exit on EOF when the workers' clients close.
fn serveConc(cs: *ConcStub) void {
    var handlers: [2]std.Thread = undefined;
    var n: usize = 0;
    while (n < handlers.len) : (n += 1) {
        const stream = cs.listener.accept(cs.io) catch break;
        handlers[n] = std.Thread.spawn(.{}, serveConcConn, .{ cs, stream }) catch {
            stream.close(cs.io);
            break;
        };
    }
    for (handlers[0..n]) |h| h.join();
}

const WorkerCtx = struct {
    g: *ghcr.GhcrClient,
    http: *client.HttpClient,
    sink: std.Io.Writer.Allocating,
    ok: bool = false,
};

fn concWorker(ctx: *WorkerCtx) void {
    ctx.g.downloadBlob(ctx.http, "homebrew/core/tree", "sha256:abc", &ctx.sink.writer, null) catch return;
    ctx.ok = true;
}

test "concurrent downloadBlob workers recover from 401 without cache corruption" {
    // Registry-wide revocation: two workers sharing one GhcrClient each hit a
    // 401 and invalidate + re-fetch the shared token. That re-fetch storm is
    // by design (extra /token round-trips), but the mutex-guarded cache must
    // never corrupt or leak — both downloads complete and the testing
    // allocator reports no leak.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var cs = ConcStub{ .io = io, .listener = &listener };
    const server_thread = try std.Thread.spawn(.{}, serveConc, .{&cs});

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner1: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http1 = client.HttpClient.initWith(&inner1, io, std.process.Environ.empty, std.testing.allocator);
    var inner2: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http2 = client.HttpClient.initWith(&inner2, io, std.process.Environ.empty, std.testing.allocator);

    var g = ghcr.GhcrClient.init(io, std.testing.allocator, &http1);
    defer g.deinit();
    g.base_url = base;

    var w1 = WorkerCtx{ .g = &g, .http = &http1, .sink = .init(std.testing.allocator) };
    var w2 = WorkerCtx{ .g = &g, .http = &http2, .sink = .init(std.testing.allocator) };
    defer w1.sink.deinit();
    defer w2.sink.deinit();

    const t1 = try std.Thread.spawn(.{}, concWorker, .{&w1});
    const t2 = try std.Thread.spawn(.{}, concWorker, .{&w2});
    t1.join();
    t2.join();

    // Close both clients so the server handlers see EOF and exit, then join.
    http1.deinit();
    http2.deinit();
    server_thread.join();

    try std.testing.expect(w1.ok);
    try std.testing.expect(w2.ok);
    try std.testing.expectEqualStrings(blob_body, w1.sink.writer.buffered());
    try std.testing.expectEqualStrings(blob_body, w2.sink.writer.buffered());
    // Each worker fetched, hit 401, invalidated, re-fetched: at least the two
    // initial fetches happened (the exact total races by design).
    try std.testing.expect(cs.token_count.load(.monotonic) >= 2);
}
