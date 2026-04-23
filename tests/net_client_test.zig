//! malt — net/client tests
//! Covers the TLS downgrade guard; the full request path is
//! exercised via smoke scripts against real endpoints.

const std = @import("std");
const testing = std.testing;
const client = @import("malt").client;

test "schemeIsHttps: https accepted" {
    try testing.expect(client.schemeIsHttps("https"));
}

test "schemeIsHttps: case-insensitive" {
    try testing.expect(client.schemeIsHttps("HTTPS"));
    try testing.expect(client.schemeIsHttps("Https"));
}

test "schemeIsHttps: http rejected" {
    try testing.expect(!client.schemeIsHttps("http"));
}

test "schemeIsHttps: empty rejected" {
    try testing.expect(!client.schemeIsHttps(""));
}

test "schemeIsHttps: unrelated schemes rejected" {
    try testing.expect(!client.schemeIsHttps("ftp"));
    try testing.expect(!client.schemeIsHttps("file"));
    try testing.expect(!client.schemeIsHttps("https-but-not-quite"));
}

test "schemeIsHttps: substring traps rejected" {
    // An attacker who can influence the scheme byte comparison
    // shouldn't sneak through with `httpsx` or `xhttps`.
    try testing.expect(!client.schemeIsHttps("httpsx"));
    try testing.expect(!client.schemeIsHttps("xhttps"));
}

test "HeadResolved.deinit: frees final_url and content_disposition when both set" {
    var head: client.HttpClient.HeadResolved = .{
        .final_url = try testing.allocator.dupe(u8, "https://a.example/x"),
        .content_disposition = try testing.allocator.dupe(u8, "attachment; filename=x"),
        .allocator = testing.allocator,
    };
    head.deinit();
}

test "HeadResolved.deinit: handles null content_disposition" {
    var head: client.HttpClient.HeadResolved = .{
        .final_url = try testing.allocator.dupe(u8, "https://a.example/x"),
        .content_disposition = null,
        .allocator = testing.allocator,
    };
    head.deinit();
}

test "HeadResolved.replaceFinalUrl: swaps to new dupe and frees the old" {
    var head: client.HttpClient.HeadResolved = .{
        .final_url = try testing.allocator.dupe(u8, "https://a.example/x"),
        .content_disposition = null,
        .allocator = testing.allocator,
    };
    defer head.deinit();

    try head.replaceFinalUrl("https://b.example/y");
    try testing.expectEqualStrings("https://b.example/y", head.final_url);
}

test "HeadResolved.replaceFinalUrl: dupe failure preserves original and leaks nothing" {
    // Mirrors the redirect-loop rotation: if the new dupe fails, the old
    // url stays owned and the caller's errdefer head.deinit() reclaims it.
    // fail_index=1 lets the initial dupe succeed and trips replaceFinalUrl's.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var head: client.HttpClient.HeadResolved = .{
        .final_url = try failing.allocator().dupe(u8, "https://a.example/x"),
        .content_disposition = null,
        .allocator = failing.allocator(),
    };
    defer head.deinit();

    try testing.expectError(error.OutOfMemory, head.replaceFinalUrl("https://b.example/y"));
    try testing.expectEqualStrings("https://a.example/x", head.final_url);
}

test "HeadResolved.replaceFinalUrl: dupe failure with content_disposition set leaks nothing" {
    // The CD-set branch is the second leak path called out in the bug:
    // a redirect that fails to dupe its location must not strand cd_result.
    // Indices: 0 = url dupe, 1 = cd dupe, 2 = replaceFinalUrl dupe (fails).
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var head: client.HttpClient.HeadResolved = .{
        .final_url = try failing.allocator().dupe(u8, "https://a.example/x"),
        .content_disposition = try failing.allocator().dupe(u8, "attachment; filename=x"),
        .allocator = failing.allocator(),
    };
    defer head.deinit();

    try testing.expectError(error.OutOfMemory, head.replaceFinalUrl("https://b.example/y"));
    try testing.expectEqualStrings("https://a.example/x", head.final_url);
    try testing.expectEqualStrings("attachment; filename=x", head.content_disposition.?);
}

test "HttpClient.headResolved: returns OOM with no leak when initial url dupe fails" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var http = client.HttpClient.init(failing.allocator());
    defer http.deinit();

    try testing.expectError(error.OutOfMemory, http.headResolved("https://example.com/"));
}

// ── Download error classification ──────────────────────────────────

test "classifyStatus: 200 is not an error" {
    try testing.expectEqual(@as(?client.DownloadError, null), client.classifyStatus(200));
}

test "classifyStatus: 301 redirect is not an error" {
    try testing.expectEqual(@as(?client.DownloadError, null), client.classifyStatus(301));
}

test "classifyStatus: 404 is HttpClientError" {
    try testing.expectEqual(@as(?client.DownloadError, error.HttpClientError), client.classifyStatus(404));
}

test "classifyStatus: 410 is HttpClientError" {
    try testing.expectEqual(@as(?client.DownloadError, error.HttpClientError), client.classifyStatus(410));
}

test "classifyStatus: 429 is RateLimited" {
    try testing.expectEqual(@as(?client.DownloadError, error.RateLimited), client.classifyStatus(429));
}

test "classifyStatus: 500 is HttpServerError" {
    try testing.expectEqual(@as(?client.DownloadError, error.HttpServerError), client.classifyStatus(500));
}

test "classifyStatus: 503 is HttpServerError" {
    try testing.expectEqual(@as(?client.DownloadError, error.HttpServerError), client.classifyStatus(503));
}

test "isTransientError: Timeout is transient" {
    try testing.expect(client.isTransientError(error.Timeout));
}

test "isTransientError: ConnectionReset is transient" {
    try testing.expect(client.isTransientError(error.ConnectionReset));
}

test "isTransientError: HttpServerError is transient" {
    try testing.expect(client.isTransientError(error.HttpServerError));
}

test "isTransientError: RateLimited is transient" {
    try testing.expect(client.isTransientError(error.RateLimited));
}

test "isTransientError: HttpClientError is permanent" {
    try testing.expect(!client.isTransientError(error.HttpClientError));
}

test "isTransientError: TlsDowngradeRefused is permanent" {
    try testing.expect(!client.isTransientError(error.TlsDowngradeRefused));
}

test "DownloadDiagnostic.isPermanent: 404 is permanent" {
    const d = client.DownloadDiagnostic{
        .status = 404,
        .url = "https://ghcr.io/v2/homebrew/core/rust/blobs/sha256:abc",
        .bytes_read = 0,
        .err = error.HttpClientError,
    };
    try testing.expect(d.isPermanent());
}

test "DownloadDiagnostic.isPermanent: 410 is permanent" {
    const d = client.DownloadDiagnostic{
        .status = 410,
        .url = "https://ghcr.io/v2/homebrew/core/rust/blobs/sha256:abc",
        .bytes_read = 0,
        .err = error.HttpClientError,
    };
    try testing.expect(d.isPermanent());
}

test "DownloadDiagnostic.isPermanent: 403 is not permanent" {
    const d = client.DownloadDiagnostic{
        .status = 403,
        .url = "https://ghcr.io/v2/homebrew/core/rust/blobs/sha256:abc",
        .bytes_read = 0,
        .err = error.HttpClientError,
    };
    try testing.expect(!d.isPermanent());
}

test "DownloadDiagnostic.isPermanent: 500 is not permanent" {
    const d = client.DownloadDiagnostic{
        .status = 500,
        .url = "https://ghcr.io/v2/homebrew/core/rust/blobs/sha256:abc",
        .bytes_read = 42,
        .err = error.HttpServerError,
    };
    try testing.expect(!d.isPermanent());
}

test "DownloadDiagnostic.isPermanent: TlsDowngradeRefused is permanent" {
    const d = client.DownloadDiagnostic{
        .status = null,
        .url = "https://ghcr.io/...",
        .bytes_read = 0,
        .err = error.TlsDowngradeRefused,
    };
    try testing.expect(d.isPermanent());
}

// ── Scaled timeout ─────────────────────────────────────────────────

test "scaledTimeoutNs: null content_length returns floor (30s)" {
    try testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), client.scaledTimeoutNs(null));
}

test "scaledTimeoutNs: small file returns floor" {
    // 1 MiB at 64 KiB/s = 16 s, below 30 s floor
    try testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), client.scaledTimeoutNs(1024 * 1024));
}

test "scaledTimeoutNs: 500 MiB file gets generous timeout" {
    const cl: u64 = 500 * 1024 * 1024;
    const result = client.scaledTimeoutNs(cl);
    // 500 MiB / 64 KiB/s = 8000 s
    try testing.expectEqual(@as(u64, 8000 * std.time.ns_per_s), result);
}

test "scaledTimeoutNs: 0-length file returns floor" {
    try testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), client.scaledTimeoutNs(0));
}

test "scaledTimeoutNs: null combined with blob_timeout_ns keeps 10-min minimum" {
    // Blob downloads use @max(blob_timeout_ns, scaledTimeoutNs(cl)).
    // When Content-Length is null (chunked), scaledTimeoutNs returns 30s,
    // but the blob floor must dominate.
    const blob_timeout = 600 * std.time.ns_per_s;
    const scaled = client.scaledTimeoutNs(null);
    try testing.expect(@max(blob_timeout, scaled) == blob_timeout);
}

// ── Retry short-circuit: permanent errors must not retry ───────────

test "classifyStatus + isTransientError: 404 is not retried" {
    const err = client.classifyStatus(404).?;
    try testing.expect(!client.isTransientError(err));
}

test "classifyStatus + isTransientError: 410 is not retried" {
    const err = client.classifyStatus(410).?;
    try testing.expect(!client.isTransientError(err));
}

test "classifyStatus + isTransientError: 500 is retried" {
    const err = client.classifyStatus(500).?;
    try testing.expect(client.isTransientError(err));
}

test "classifyStatus + isTransientError: 429 is retried" {
    const err = client.classifyStatus(429).?;
    try testing.expect(client.isTransientError(err));
}
