//! malt — net/ghcr tests
//! Covers GhcrClient.init/deinit plumbing without hitting the network.

const std = @import("std");
const testing = std.testing;
const client_mod = @import("malt").client;
const ghcr = @import("malt").ghcr;
const io_mod = @import("malt").io_mod;

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

// ── GHCR error classification ──────────────────────────────────────

test "classifyGhcrStatus: 404 maps to DownloadHttpClientError" {
    try testing.expectEqual(ghcr.GhcrError.DownloadHttpClientError, ghcr.GhcrClient.classifyGhcrStatus(404));
}

test "classifyGhcrStatus: 410 maps to DownloadHttpClientError" {
    try testing.expectEqual(ghcr.GhcrError.DownloadHttpClientError, ghcr.GhcrClient.classifyGhcrStatus(410));
}

test "classifyGhcrStatus: 429 maps to DownloadRateLimited" {
    try testing.expectEqual(ghcr.GhcrError.DownloadRateLimited, ghcr.GhcrClient.classifyGhcrStatus(429));
}

test "classifyGhcrStatus: 500 maps to DownloadHttpServerError" {
    try testing.expectEqual(ghcr.GhcrError.DownloadHttpServerError, ghcr.GhcrClient.classifyGhcrStatus(500));
}

test "classifyGhcrStatus: 503 maps to DownloadHttpServerError" {
    try testing.expectEqual(ghcr.GhcrError.DownloadHttpServerError, ghcr.GhcrClient.classifyGhcrStatus(503));
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

test "fetchToken on cache hit returns an owned dupe the caller must free" {
    // Pin the owned-return contract: the slice handed back is a fresh
    // allocation, distinct from `cached_token`. If fetchToken ever
    // reverts to a borrow, this test double-frees the cached buffer
    // and the testing allocator aborts the run.
    var pool = try client_mod.HttpClientPool.init(testing.allocator, 1);
    defer pool.deinit();
    const http = pool.acquire();
    defer pool.release(http);

    var g = ghcr.GhcrClient.init(testing.allocator, http);
    defer g.deinit();

    const seeded_token = try testing.allocator.dupe(u8, "fake-token");
    const seeded_repo = try testing.allocator.dupe(u8, "homebrew/core/wget");
    g.cached_token = seeded_token;
    try g.cached_scopes.put(testing.allocator, seeded_repo, {});
    g.token_expiry = std.math.maxInt(i64);

    const token = try g.fetchToken(http, "homebrew/core/wget");
    defer testing.allocator.free(token);

    try testing.expectEqualStrings("fake-token", token);
    try testing.expect(token.ptr != seeded_token.ptr);
}

// Concurrent stress: one churner replaces the cached token in a tight
// loop (the mutex-protected half of `prefetchTokens`) while four
// fetchers call fetchToken on the same repo. With a borrowed return
// the churner's free would race the fetchers' use — `testing.allocator`
// catches the resulting double-free or leak. Owned-dupe returns give
// every fetcher an independent allocation, so the loop stays clean.
test "fetchToken is safe against concurrent cache churn" {
    const fetchers: usize = 4;
    const iterations: usize = 2000;

    var pool = try client_mod.HttpClientPool.init(testing.allocator, 1);
    defer pool.deinit();
    const http = pool.acquire();
    defer pool.release(http);

    var g = ghcr.GhcrClient.init(testing.allocator, http);
    defer g.deinit();

    // Initial seed so fetchers never miss and reach the network path.
    g.cached_token = try testing.allocator.dupe(u8, "tok-0");
    try g.cached_scopes.put(
        testing.allocator,
        try testing.allocator.dupe(u8, "homebrew/core/wget"),
        {},
    );
    g.token_expiry = std.math.maxInt(i64);

    const stop = std.atomic.Value(bool);
    var done: stop = .init(false);

    const Churn = struct {
        fn run(gc: *ghcr.GhcrClient, flag: *stop, iters: usize) void {
            const io = io_mod.ctx();
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                gc.mutex.lockUncancelable(io);
                // Clear + reseed atomically under the mutex; mirrors
                // the prefetchTokens window where cached_token is
                // replaced with a fresh allocation.
                if (gc.cached_token) |t| testing.allocator.free(t);
                var it = gc.cached_scopes.keyIterator();
                while (it.next()) |k| testing.allocator.free(k.*);
                gc.cached_scopes.clearRetainingCapacity();

                const fresh_tok = testing.allocator.dupe(u8, "tok-n") catch {
                    gc.cached_token = null;
                    gc.token_expiry = 0;
                    gc.mutex.unlock(io);
                    return;
                };
                const fresh_repo = testing.allocator.dupe(u8, "homebrew/core/wget") catch {
                    testing.allocator.free(fresh_tok);
                    gc.cached_token = null;
                    gc.token_expiry = 0;
                    gc.mutex.unlock(io);
                    return;
                };
                gc.cached_scopes.put(testing.allocator, fresh_repo, {}) catch {
                    testing.allocator.free(fresh_tok);
                    testing.allocator.free(fresh_repo);
                    gc.cached_token = null;
                    gc.token_expiry = 0;
                    gc.mutex.unlock(io);
                    return;
                };
                gc.cached_token = fresh_tok;
                gc.token_expiry = std.math.maxInt(i64);
                gc.mutex.unlock(io);
            }
            flag.store(true, .release);
        }
    };

    const Fetch = struct {
        fn run(gc: *ghcr.GhcrClient, cli: *client_mod.HttpClient, flag: *stop) void {
            while (!flag.load(.acquire)) {
                const tok = gc.fetchToken(cli, "homebrew/core/wget") catch continue;
                // Touch the bytes so the read races the churner's free
                // under the old borrowed-return behaviour.
                var sum: usize = 0;
                for (tok) |b| sum +%= b;
                std.mem.doNotOptimizeAway(sum);
                testing.allocator.free(tok);
            }
        }
    };

    const threads = try testing.allocator.alloc(std.Thread, fetchers + 1);
    defer testing.allocator.free(threads);

    threads[0] = try std.Thread.spawn(.{}, Churn.run, .{ &g, &done, iterations });
    for (threads[1..]) |*t| t.* = try std.Thread.spawn(.{}, Fetch.run, .{ &g, http, &done });
    for (threads) |t| t.join();
}
