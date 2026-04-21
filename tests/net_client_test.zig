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
