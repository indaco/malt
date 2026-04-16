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
    try testing.expectEqual(@as(usize, 0), g.cached_scopes.count());
    try testing.expectEqual(@as(i64, 0), g.token_expiry);
}

// S10: GHCR multi-scope token prefetch. GHCR's /token endpoint accepts
// multiple `scope=repository:<repo>:pull` query params and returns one
// token valid for every requested scope. `buildTokenUrl` is the pure
// URL-shape half of the prefetch; the network-hitting half needs a
// live GHCR to validate and is exercised by manual installs. These
// tests pin the URL contract so a future refactor can't silently
// break the multi-scope request shape.

test "buildTokenUrl emits one scope param for a single repo" {
    const repos = [_][]const u8{"homebrew/core/wget"};
    const url = try ghcr.GhcrClient.buildTokenUrl(testing.allocator, &repos);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://ghcr.io/token?scope=repository:homebrew/core/wget:pull",
        url,
    );
}

test "buildTokenUrl joins multiple scopes with '&' in input order" {
    const repos = [_][]const u8{
        "homebrew/core/tree",
        "homebrew/core/wget",
        "homebrew/core/openssl/3",
    };
    const url = try ghcr.GhcrClient.buildTokenUrl(testing.allocator, &repos);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://ghcr.io/token?" ++
            "scope=repository:homebrew/core/tree:pull&" ++
            "scope=repository:homebrew/core/wget:pull&" ++
            "scope=repository:homebrew/core/openssl/3:pull",
        url,
    );
}

test "buildTokenUrl returns just the prefix on an empty repo list" {
    // prefetchTokens short-circuits on empty input, but the URL builder
    // stays well-defined — no scope params, just the endpoint path.
    const repos = [_][]const u8{};
    const url = try ghcr.GhcrClient.buildTokenUrl(testing.allocator, &repos);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://ghcr.io/token?", url);
}

test "hasTokenFor is false before any fetch and true after a direct cache seed" {
    // Black-box probe: without hitting the network we can still verify
    // the scope-set cache behaves the way fetchToken / prefetchTokens
    // promise. Seed the cache by hand, then probe.
    var pool = try client_mod.HttpClientPool.init(testing.allocator, 1);
    defer pool.deinit();
    const http = pool.acquire();
    defer pool.release(http);

    var g = ghcr.GhcrClient.init(testing.allocator, http);
    defer g.deinit();

    try testing.expect(!g.hasTokenFor("homebrew/core/wget"));

    const fake_token = try testing.allocator.dupe(u8, "fake-token");
    const fake_repo = try testing.allocator.dupe(u8, "homebrew/core/wget");
    g.cached_token = fake_token;
    try g.cached_scopes.put(testing.allocator, fake_repo, {});
    g.token_expiry = std.math.maxInt(i64); // effectively never expires

    try testing.expect(g.hasTokenFor("homebrew/core/wget"));
    try testing.expect(!g.hasTokenFor("homebrew/core/tree"));
}

test "hasTokenFor treats expired tokens as cache-miss" {
    var pool = try client_mod.HttpClientPool.init(testing.allocator, 1);
    defer pool.deinit();
    const http = pool.acquire();
    defer pool.release(http);

    var g = ghcr.GhcrClient.init(testing.allocator, http);
    defer g.deinit();

    const fake_token = try testing.allocator.dupe(u8, "fake-token");
    const fake_repo = try testing.allocator.dupe(u8, "homebrew/core/wget");
    g.cached_token = fake_token;
    try g.cached_scopes.put(testing.allocator, fake_repo, {});
    g.token_expiry = 0; // far in the past

    try testing.expect(!g.hasTokenFor("homebrew/core/wget"));
}
