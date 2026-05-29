//! malt — net/client_pool seam test
//! Guards the public module boundary: a consumer can borrow and return
//! `HttpClient`s through `malt.client_pool` alone, without importing the
//! full `net/client` surface (and its idle-watchdog / redirect machinery).
//! Pool behaviour itself is unit-tested inline in src/net/client_pool.zig.

const std = @import("std");
const testing = std.testing;
const pool_mod = @import("malt").client_pool;

test "client_pool exposes a usable pool + borrowed HttpClient via its own module" {
    var pool = try pool_mod.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator, 1);
    defer pool.deinit();

    const c: *pool_mod.HttpClient = pool.acquire();
    try testing.expect(!c.offline); // borrowed client is the real type, default online
    pool.release(c);
}

test "HttpClientPool lives only in client_pool, not re-exported from client" {
    // The transition re-export from net/client.zig is gone — callers import
    // the pool from its own module, keeping the client↔pool import cycle broken.
    try testing.expect(@hasDecl(@import("malt").client_pool, "HttpClientPool"));
    try testing.expect(!@hasDecl(@import("malt").client, "HttpClientPool"));
}
