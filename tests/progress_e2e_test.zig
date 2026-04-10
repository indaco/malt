//! malt — progress integration test
//! End-to-end test: fetch a real HTTP resource and verify the ProgressCallback fires.

const std = @import("std");
const testing = std.testing;
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

test "HTTP GET with progress callback fires correctly" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();

    var tracker = TestTracker{
        .bar = progress_mod.ProgressBar.init("e2e-test", 0),
    };
    const cb = client_mod.ProgressCallback{
        .context = @ptrCast(&tracker),
        .func = &TestTracker.callback,
    };

    // Fetch a small, stable public URL (Homebrew API formula JSON for jq — ~3 KB)
    var resp = http.getWithHeaders(
        "https://formulae.brew.sh/api/formula/jq.json",
        &.{},
        cb,
    ) catch |err| {
        // Network may be unavailable in CI — skip rather than fail
        std.debug.print("Skipping e2e test (network error: {s})\n", .{@errorName(err)});
        return;
    };
    defer resp.deinit();

    tracker.bar.finish();

    // The callback should have been called at least once
    try testing.expect(tracker.call_count > 0);
    // Last bytes should match the response body length
    try testing.expectEqual(@as(u64, resp.body.len), tracker.last_bytes);
    // HTTP 200
    try testing.expectEqual(@as(u16, 200), resp.status);
}

test "HTTP GET without progress (null) still works" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();

    // Use get() which goes through the standard metadata path (no progress)
    var resp = http.get(
        "https://formulae.brew.sh/api/formula/jq.json",
    ) catch |err| {
        std.debug.print("Skipping e2e test (network error: {s})\n", .{@errorName(err)});
        return;
    };
    defer resp.deinit();

    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(resp.body.len > 100);
}
