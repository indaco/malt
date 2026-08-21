//! malt - bottle-download cancellation integration tests.
//!
//! Pins that a Ctrl-C is honoured *inside* a single formula's download, not
//! only between queued jobs. `downloadBottleToStore` retries a transient
//! failure three times; with the interrupt flag raised it must stop at the
//! attempt in flight and stay quiet, so the caller reports the interruption
//! once instead of the loop misreporting it as a download failure.
//!
//! A loopback `std.http.Server` answers `/token` and `/blobs/…` with a
//! retryable 500, so every attempt is transient and the only thing that can
//! shorten the loop is the interrupt poll. No real network.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const client = malt.client;
const download = malt.install_download;
const formula_mod = malt.formula;
const ghcr = malt.ghcr;
const signals = malt.signals;
const store_mod = malt.store;
const net = std.Io.net;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const bottle_sha = "1111111111111111111111111111111111111111111111111111111111111111";

const Stub = struct {
    io: std.Io,
    listener: *net.Server,
    blob_count: usize = 0,
    // When true the blob GET succeeds with bytes that cannot hash to the
    // expected digest, so the attempt fails as a mismatch rather than a 500.
    corrupt_body: bool = false,
    // Raises the interrupt flag while this numbered blob GET is being served,
    // i.e. with that attempt already in flight.
    flag_on_blob: ?usize = null,
};

// Keep-alive loop: every blob GET answers a retryable 500 so the install
// loop treats each attempt as transient and would re-dial until it exhausts
// its budget. Ends when the client closes and `receiveHead` fails.
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
            s.blob_count += 1;
            if (s.flag_on_blob) |n| {
                if (s.blob_count == n) malt.signals.setInterruptedForTest(true);
            }
            if (s.corrupt_body) {
                req.respond("not-the-expected-bytes", .{}) catch return;
            } else {
                req.respond("boom\n", .{ .status = .internal_server_error }) catch return;
            }
        } else {
            req.respond("not found\n", .{ .status = .not_found }) catch return;
        }
    }
}

// Counts the per-keg failure lines the loop emits so a test can assert the
// "(after N attempts)" misreport is gone without matching terminal output.
const RecordingSink = struct {
    errs: usize = 0,
    last: [256]u8 = undefined,
    last_len: usize = 0,

    fn writeErr(ctx: ?*anyopaque, msg: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        self.errs += 1;
        const n = @min(msg.len, self.last.len);
        @memcpy(self.last[0..n], msg[0..n]);
        self.last_len = n;
    }
    fn writeNoop(_: ?*anyopaque, _: []const u8) void {}

    fn text(self: *const RecordingSink) []const u8 {
        return self.last[0..self.last_len];
    }
};

const formula_json =
    \\{
    \\  "name": "cancelpkg",
    \\  "full_name": "cancelpkg",
    \\  "tap": "homebrew/core",
    \\  "desc": "",
    \\  "homepage": "",
    \\  "versions": {"stable": "1.0"},
    \\  "revision": 0,
    \\  "dependencies": [],
    \\  "keg_only": false,
    \\  "post_install_defined": false,
    \\  "oldnames": [],
    \\  "bottle": {"stable": {"files": {}}}
    \\}
;

fn setupPrefix(tag: []const u8) ![:0]u8 {
    const base = try test_io.uniqueTempPath(testing.allocator, "install_dl_cancel", tag);
    defer testing.allocator.free(base);
    const path = try testing.allocator.dupeZ(u8, base);
    inline for (.{ "store", "tmp", "db" }) |sub| {
        const dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, sub });
        defer testing.allocator.free(dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, dir);
    }
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

/// Outcome of one `downloadBottleToStore` run against the always-500 stub.
/// Counts what survives under `<prefix>/tmp`; 0 means the scratch dir was
/// reclaimed. Errors propagate - a helper that silently returned 0 would let
/// a leak pass as a clean run.
fn countTmpEntries(prefix: []const u8) !usize {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/tmp", .{prefix});
    var dir = try test_io.openDirAbsolute(std.Options.debug_io, path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(std.Options.debug_io)) |_| n += 1;
    return n;
}

const Run = struct {
    result: anyerror!bool,
    blob_gets: usize,
    sink: RecordingSink,
    /// Entries left under `<prefix>/tmp` once the call returns. A cancelled
    /// download must not strand its scratch dir - nothing sweeps that path.
    tmp_leftovers: usize,
};

/// Drive the retry loop once with whatever interrupt state the caller armed.
/// Everything (prefix, db, stub) is owned and torn down here so each test
/// body is just arrange-flag → run → assert.
fn runDownload(tag: []const u8, corrupt_body: bool, flag_on_blob: ?usize) !Run {
    const prefix = try setupPrefix(tag);
    defer {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);
    // Empty budget: net answers the 500 straight back, so one blob GET means
    // exactly one install-loop attempt.
    http.retry_backoff_ms = &.{};

    var g = ghcr.GhcrClient.init(io, testing.allocator, &http);
    defer g.deinit();
    g.base_url = base;

    var db = try malt.sqlite.Database.open(":memory:");
    defer db.close();
    var store = store_mod.Store.init(io, testing.allocator, &db, prefix);

    var rec = RecordingSink{};
    var f = try formula_mod.parseFormula(testing.allocator, formula_json);
    defer f.deinit();

    // Spawn last: nothing below can fail, so the join at the end is always
    // reached and the stub thread can never outlive this frame.
    var stub = Stub{ .io = io, .listener = &listener, .corrupt_body = corrupt_body, .flag_on_blob = flag_on_blob };
    const server_thread = try std.Thread.spawn(.{}, serveStub, .{&stub});

    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = .empty };
    const result = download.downloadBottleToStore(&ctx, testing.allocator, .{
        .ghcr = &g,
        .http = &http,
        .store = &store,
        .sink = .{
            .ctx = &rec,
            .writeInfo = RecordingSink.writeNoop,
            .writeWarn = RecordingSink.writeNoop,
            .writeSuccess = RecordingSink.writeNoop,
            .writeErr = RecordingSink.writeErr,
        },
    }, &f, .{
        .cellar = ":any",
        .url = "https://ghcr.io/v2/homebrew/core/cancelpkg/blobs/sha256:" ++ bottle_sha,
        .sha256 = bottle_sha,
    });

    // Close the client so the stub's keep-alive loop ends, then join before
    // reading its counter to avoid a data race. A cancelled run issues no
    // request at all, so the stub may still be parked in accept() - one
    // throwaway connection wakes it and keeps the join bounded.
    http.deinit();
    var wake_addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    if (net.IpAddress.connect(&wake_addr, io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
    server_thread.join();

    return .{
        .result = result,
        .blob_gets = stub.blob_count,
        .sink = rec,
        .tmp_leftovers = try countTmpEntries(prefix),
    };
}

test "an interrupt raised before the download starts issues no request at all" {
    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    signals.setInterruptedForTest(true);

    const run = try runDownload("pre", false, null);

    try testing.expectError(malt.install_record.InstallError.DownloadFailed, run.result);
    try testing.expectEqual(@as(usize, 0), run.blob_gets);
    // The caller prints the interruption; the loop must add nothing.
    try testing.expectEqual(@as(usize, 0), run.sink.errs);
    // Breaking before the first attempt skips the per-attempt cleanup, so the
    // scratch dir has to be reclaimed on the way out.
    try testing.expectEqual(@as(usize, 0), run.tmp_leftovers);
}

test "an interrupt during the first attempt stops the retry loop at one request" {
    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    signals.setInterruptedForTest(false);
    // The loop polls once per attempt: poll 1 lets attempt 1 run, poll 2 fires.
    signals.armInterruptAfterForTest(2);
    defer signals.armInterruptAfterForTest(0);

    const run = try runDownload("mid", false, null);

    try testing.expectError(malt.install_record.InstallError.DownloadFailed, run.result);
    try testing.expectEqual(@as(usize, 1), run.blob_gets);
    try testing.expectEqual(@as(usize, 0), run.sink.errs);
}

test "an uninterrupted transient failure still burns the full retry budget" {
    // Guards the fix against over-reach: without an interrupt the loop keeps
    // its three attempts and its attempts-exhausted diagnostic.
    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    signals.setInterruptedForTest(false);

    const run = try runDownload("full", false, null);

    try testing.expectError(malt.install_record.InstallError.DownloadFailed, run.result);
    try testing.expectEqual(@as(usize, 3), run.blob_gets);
    try testing.expectEqual(@as(usize, 1), run.sink.errs);
    try testing.expect(std.mem.indexOf(u8, run.sink.text(), "after 3 attempts") != null);
}

test "a cancel keeps a real mismatch diagnostic but drops the attempts line" {
    // The fix suppresses only the attempts-exhausted misreport. A checksum
    // mismatch actually happened, so that line stays - pinning which of the
    // two diagnostics the cancellation path is allowed to silence.
    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    signals.setInterruptedForTest(false);
    signals.armInterruptAfterForTest(2);
    defer signals.armInterruptAfterForTest(0);

    const run = try runDownload("mismatch", true, null);

    try testing.expectError(malt.install_record.InstallError.DownloadFailed, run.result);
    try testing.expectEqual(@as(usize, 1), run.blob_gets);
    try testing.expectEqual(@as(usize, 1), run.sink.errs);
    try testing.expect(std.mem.indexOf(u8, run.sink.text(), "Sha256Mismatch") != null);
    try testing.expect(std.mem.indexOf(u8, run.sink.text(), "after 3 attempts") == null);
}

test "an interrupt before the last attempt stops the retry loop at two requests" {
    // Arms the poll that guards attempt 3, so attempts 1 and 2 run and both
    // backoff entries are indexed - the case that would trip an off-by-one in
    // the delay table under a live cancel.
    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    signals.setInterruptedForTest(false);
    signals.armInterruptAfterForTest(3);
    defer signals.armInterruptAfterForTest(0);

    const run = try runDownload("late", false, null);

    try testing.expectError(malt.install_record.InstallError.DownloadFailed, run.result);
    try testing.expectEqual(@as(usize, 2), run.blob_gets);
    try testing.expectEqual(@as(usize, 0), run.sink.errs);
    try testing.expectEqual(@as(usize, 0), run.tmp_leftovers);
}

test "an interrupt during the last attempt is not reported as an exhausted budget" {
    // The loop polls before each attempt, so a flag raised while the final
    // attempt is already in flight escapes it. The report gate re-checks, or
    // this window prints the exact misreport the fix removes.
    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    signals.setInterruptedForTest(false);

    const run = try runDownload("last", false, 3);

    try testing.expectError(malt.install_record.InstallError.DownloadFailed, run.result);
    try testing.expectEqual(@as(usize, 3), run.blob_gets);
    try testing.expectEqual(@as(usize, 0), run.sink.errs);
    try testing.expectEqual(@as(usize, 0), run.tmp_leftovers);
}
