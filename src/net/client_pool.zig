//! Borrow/return pool of `HttpClient`s, split out of `net/client.zig`
//! so pool-only tests link here without dragging in the idle-watchdog
//! and redirect state machines that live alongside `HttpClient`.

const std = @import("std");
const client_mod = @import("client.zig");

/// Re-exported so pool consumers name the borrowed type without also
/// importing `net/client`.
pub const HttpClient = client_mod.HttpClient;

/// Thread-safe borrow/return pool of `HttpClient`s. `std.http.Client` is
/// not thread-safe, but per-request construction pays the full TLS
/// handshake every time; pooling preserves no-sharing while reusing
/// connections across the hot phase of an install.
pub const HttpClientPool = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    clients: []HttpClient,
    busy: []bool,
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,

    pub fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator, size: usize) !HttpClientPool {
        const clients = try allocator.alloc(HttpClient, size);
        errdefer allocator.free(clients);
        const busy = try allocator.alloc(bool, size);
        errdefer allocator.free(busy);
        @memset(busy, false);
        for (clients) |*c| c.* = HttpClient.init(io, environ, allocator);
        return .{
            .io = io,
            .allocator = allocator,
            .clients = clients,
            .busy = busy,
            .mutex = .init,
            .cond = .init,
        };
    }

    pub fn deinit(self: *HttpClientPool) void {
        for (self.clients) |*c| c.deinit();
        self.allocator.free(self.clients);
        self.allocator.free(self.busy);
    }

    /// Block until idle, mark busy, return exclusive pointer until `release`.
    pub fn acquire(self: *HttpClientPool) *HttpClient {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            for (self.busy, 0..) |b, i| {
                if (!b) {
                    self.busy[i] = true;
                    return &self.clients[i];
                }
            }
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Mirror `offline` onto every pooled client. Cli/ call sites use
    /// this right after `init` so workers borrowed under offline mode
    /// short-circuit with `OfflineRequired` rather than dialing out.
    pub fn setOfflineAll(self: *HttpClientPool, offline: bool) void {
        for (self.clients) |*c| c.offline = offline;
    }

    /// Return an acquired client; foreign pointers are a programmer error.
    pub fn release(self: *HttpClientPool, client: *HttpClient) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const base = @intFromPtr(self.clients.ptr);
        const addr = @intFromPtr(client);
        const idx = (addr - base) / @sizeOf(HttpClient);
        std.debug.assert(idx < self.clients.len);
        self.busy[idx] = false;
        self.cond.signal(self.io);
    }
};

// Pure allocator + mutex bookkeeping — no network — so the pool is fully
// unit-testable without HTTP traffic. The blocking cond.wait branch needs
// a second thread and lives in tests/progress_test.zig.

const testing = std.testing;
const test_io = std.Options.debug_io;
const empty_env = std.process.Environ.empty;

test "init seeds size clients, all idle" {
    var pool = try HttpClientPool.init(test_io, empty_env, testing.allocator, 3);
    defer pool.deinit();
    try testing.expectEqual(@as(usize, 3), pool.clients.len);
    for (pool.busy) |b| try testing.expect(!b);
}

test "acquire marks busy; release returns the same slot for reuse" {
    var pool = try HttpClientPool.init(test_io, empty_env, testing.allocator, 1);
    defer pool.deinit();

    const c1 = pool.acquire();
    try testing.expect(pool.busy[0]);
    pool.release(c1);
    try testing.expect(!pool.busy[0]);
    // Sole slot is reused, not leaked into a phantom second client.
    const c2 = pool.acquire();
    try testing.expectEqual(c1, c2);
    pool.release(c2);
}

test "acquire hands out distinct clients while several are borrowed" {
    var pool = try HttpClientPool.init(test_io, empty_env, testing.allocator, 2);
    defer pool.deinit();

    const a = pool.acquire();
    const b = pool.acquire();
    try testing.expect(a != b);
    pool.release(a);
    pool.release(b);
}

test "deinit cleans up a zero-use pool" {
    var pool = try HttpClientPool.init(test_io, empty_env, testing.allocator, 1);
    pool.deinit();
}

test "setOfflineAll mirrors the flag onto every pooled client" {
    var pool = try HttpClientPool.init(test_io, empty_env, testing.allocator, 3);
    defer pool.deinit();

    pool.setOfflineAll(true);
    for (pool.clients) |c| try testing.expect(c.offline);
    // Toggling back must clear it everywhere too.
    pool.setOfflineAll(false);
    for (pool.clients) |c| try testing.expect(!c.offline);
}

test "init propagates allocator failure on the first allocation" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        HttpClientPool.init(test_io, empty_env, failing.allocator(), 2),
    );
}

test "init propagates allocator failure on the second allocation" {
    // Failing the `busy` alloc exercises the errdefer that frees `clients`.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(
        error.OutOfMemory,
        HttpClientPool.init(test_io, empty_env, failing.allocator(), 2),
    );
}
