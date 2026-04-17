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
