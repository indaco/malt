//! malt — net/ghcr tests
//! Covers GhcrClient.init/deinit plumbing without hitting the network.

const std = @import("std");
const testing = std.testing;
const client_mod = @import("malt").client;
const ghcr = @import("malt").ghcr;

test "extractTokenField parses {\"token\":\"...\"} responses" {
    const json = "{\"token\":\"abc123\",\"expires_in\":300}";
    const token = try ghcr.extractTokenField(testing.allocator, json);
    defer testing.allocator.free(token);
    try testing.expectEqualStrings("abc123", token);
}

test "extractTokenField errors on malformed JSON" {
    try testing.expectError(error.SyntaxError, ghcr.extractTokenField(testing.allocator, "not json"));
}

test "extractTokenField returns InvalidResponse when token field is missing" {
    const json = "{\"other\":\"x\"}";
    try testing.expectError(error.InvalidResponse, ghcr.extractTokenField(testing.allocator, json));
}

test "extractTokenField returns InvalidResponse when token field is not a string" {
    const json = "{\"token\":42}";
    try testing.expectError(error.InvalidResponse, ghcr.extractTokenField(testing.allocator, json));
}

test "GhcrClient.init/deinit does not leak and starts without cached token" {
    var pool = try client_mod.HttpClientPool.init(testing.allocator, 1);
    defer pool.deinit();

    const http = pool.acquire();
    defer pool.release(http);

    var g = ghcr.GhcrClient.init(testing.allocator, http);
    defer g.deinit();

    try testing.expect(g.cached_token == null);
    try testing.expect(g.cached_repo == null);
    try testing.expectEqual(@as(i64, 0), g.token_expiry);
}
