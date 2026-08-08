//! malt — progress integration test
//! Drives a real HTTP fetch against a loopback `std.http.Server` and verifies
//! the ProgressCallback fires with the byte counts the transfer actually saw.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const client_mod = @import("malt").client;
const progress_mod = @import("malt").progress;

const TestTracker = struct {
    call_count: u32 = 0,
    last_bytes: u64 = 0,
    last_total: ?u64 = null,
    bar: progress_mod.ProgressBar,

    fn callback(ctx: *anyopaque, bytes_so_far: u64, content_length: ?u64) void {
        const self: *TestTracker = @ptrCast(@alignCast(ctx));
        self.call_count += 1;
        self.last_bytes = bytes_so_far;
        self.last_total = content_length;
        if (content_length) |total| {
            if (self.bar.total == 0) self.bar.total = total;
        }
        const clamped = if (self.bar.total > 0) @min(bytes_so_far, self.bar.total) else bytes_so_far;
        self.bar.update(clamped);
    }
};

/// Body big enough that the transfer is worth reporting on, small enough to
/// keep the fixture in the binary.
const payload = "malt-progress-fixture-" ** 256;

const Stub = struct { io: std.Io, listener: *std.Io.net.Server };

fn serve(s: *Stub) void {
    const stream = s.listener.accept(s.io) catch return;
    defer stream.close(s.io);
    var rbuf: [8 * 1024]u8 = undefined;
    var wbuf: [8 * 1024]u8 = undefined;
    var reader = stream.reader(s.io, &rbuf);
    var writer = stream.writer(s.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    var req = srv.receiveHead() catch return;
    req.respond(payload, .{}) catch return;
}

test "HTTP GET with progress callback reports every byte of the body" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();
    var stub = Stub{ .io = io, .listener = &listener };
    const t = try std.Thread.spawn(.{}, serve, .{&stub});
    defer listener.deinit(io);

    var http = client_mod.HttpClient.init(io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();

    var tracker = TestTracker{ .bar = progress_mod.ProgressBar.init("e2e-test", 0) };
    const cb = client_mod.ProgressCallback{
        .context = @ptrCast(&tracker),
        .func = &TestTracker.callback,
    };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/payload", .{port});
    var resp = try http.getWithHeaders(url, &.{}, cb);
    defer resp.deinit();
    // Join before the listener's deferred close: closing a socket a thread is
    // blocked in `accept` on is a use-after-close.
    t.join();

    tracker.bar.finish();

    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings(payload, resp.body);
    try testing.expect(tracker.call_count > 0);
    // The final tick accounts for the whole body, and the declared length
    // reached the callback so a determinate bar was possible.
    try testing.expectEqual(@as(u64, resp.body.len), tracker.last_bytes);
    try testing.expectEqual(@as(?u64, payload.len), tracker.last_total);
}

test "HTTP GET without a progress callback still returns the whole body" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();
    var stub = Stub{ .io = io, .listener = &listener };
    const t = try std.Thread.spawn(.{}, serve, .{&stub});
    defer listener.deinit(io);

    var http = client_mod.HttpClient.init(io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/payload", .{port});
    var resp = try http.get(url);
    defer resp.deinit();
    t.join();

    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings(payload, resp.body);
}
