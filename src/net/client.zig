const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const io_mod = @import("../ui/io.zig");

/// Optional progress reporting for long downloads.
/// `bytes_so_far`: total bytes received so far (after decompression).
/// `content_length`: total expected bytes from HTTP header, or null if unknown.
pub const ProgressCallback = struct {
    context: *anyopaque,
    func: *const fn (context: *anyopaque, bytes_so_far: u64, content_length: ?u64) void,

    pub fn report(self: ProgressCallback, bytes_so_far: u64, content_length: ?u64) void {
        self.func(self.context, bytes_so_far, content_length);
    }
};

pub const Response = struct {
    status: u16,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }
};

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    /// Per-request timeout in nanoseconds. Default: 30 seconds.
    timeout_ns: u64 = DEFAULT_TIMEOUT_NS,

    /// Lazily-allocated decompression windows, reused across requests. These
    /// are sized for the worst case per encoding (zstd ~128 KiB, flate
    /// 32 KiB); previously every request allocated a fresh buffer and freed
    /// it on return, which cost ~160 KiB of allocator churn per API call.
    /// A single HttpClient is borrowed from a pool per thread, so the buffer
    /// is never accessed concurrently.
    zstd_window: ?[]u8 = null,
    flate_window: ?[]u8 = null,

    const DEFAULT_TIMEOUT_NS: u64 = 30 * std.time.ns_per_s;
    /// Blob downloads (bottles, cask DMGs) get a much longer timeout.
    const BLOB_TIMEOUT_NS: u64 = 600 * std.time.ns_per_s; // 10 minutes

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io_mod.ctx() },
        };
    }

    pub fn deinit(self: *HttpClient) void {
        if (self.zstd_window) |w| self.allocator.free(w);
        if (self.flate_window) |w| self.allocator.free(w);
        self.client.deinit();
    }

    fn getZstdWindow(self: *HttpClient) ![]u8 {
        if (self.zstd_window) |w| return w;
        const w = try self.allocator.alloc(u8, std.compress.zstd.default_window_len);
        self.zstd_window = w;
        return w;
    }

    fn getFlateWindow(self: *HttpClient) ![]u8 {
        if (self.flate_window) |w| return w;
        const w = try self.allocator.alloc(u8, std.compress.flate.max_window_len);
        self.flate_window = w;
        return w;
    }

    /// Perform a GET request and return the response status and body.
    /// Automatically injects HOMEBREW_GITHUB_API_TOKEN as Authorization
    /// header for GitHub/Homebrew API requests when the env var is set.
    /// The caller owns the returned `Response` and must call `deinit` on it.
    pub fn get(self: *HttpClient, url: []const u8) !Response {
        if (fs_compat.getenv("HOMEBREW_GITHUB_API_TOKEN")) |token| {
            // Apply token to GitHub and Homebrew API requests
            if (std.mem.indexOf(u8, url, "github.com") != null or
                std.mem.indexOf(u8, url, "formulae.brew.sh") != null or
                std.mem.indexOf(u8, url, "ghcr.io") != null)
            {
                var auth_buf: [256]u8 = undefined;
                const auth_value = std.fmt.bufPrint(&auth_buf, "token {s}", .{std.mem.sliceTo(token, 0)}) catch
                    return self.doGet(url, &.{});
                const headers = [_]std.http.Header{
                    .{ .name = "Authorization", .value = auth_value },
                };
                return self.doGet(url, &headers);
            }
        }
        return self.doGet(url, &.{});
    }

    /// Perform a GET request with extra headers (e.g. Authorization for blob downloads).
    /// Uses the larger MAX_BLOB_BYTES limit since this is typically used for bottle downloads.
    /// The caller owns the returned `Response` and must call `deinit` on it.
    pub fn getWithHeaders(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        progress: ?ProgressCallback,
    ) !Response {
        return self.doGetWithRetry(url, extra_headers, MAX_BLOB_BYTES, progress);
    }

    /// Perform a HEAD request and return only the HTTP status code.
    pub fn head(self: *HttpClient, url: []const u8) !u16 {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.HEAD, uri, .{
            .extra_headers = &.{},
        });
        defer req.deinit();

        try req.sendBodiless();

        // 32 KiB header buffer — GHCR's `/token` and blob redirects can
        // exceed 8 KiB once cookies, signed-URL params, and multi-scope
        // token responses stack up. 0.15 capped at 8 KiB and occasionally
        // tripped `HeaderBufferTooSmall` on cold installs.
        var redirect_buf: [32 * 1024]u8 = undefined;
        const response = try req.receiveHead(&redirect_buf);

        return @intFromEnum(response.head.status);
    }

    /// Default maximum response body size for metadata (API JSON, tokens, etc.).
    /// The full Homebrew formula.json index is ~25 MB; 50 MB gives headroom.
    /// Bottle downloads bypass this via getWithHeaders (which sets no limit).
    const MAX_METADATA_BYTES: usize = 50 * 1024 * 1024;

    /// Bottle responses can be 500+ MB. We cap at 2 GB to prevent true OOM.
    const MAX_BLOB_BYTES: usize = 2 * 1024 * 1024 * 1024;

    // ---- internal helper ----

    const MAX_RETRIES = 3;
    const RETRY_DELAYS_MS = [_]u64{ 1000, 2000, 4000 };

    /// Writer wrapper that counts bytes written, enforces an upper bound, and
    /// optionally fires a progress callback. The bound is checked on every
    /// write so oversized responses are rejected mid-stream instead of after
    /// the full body has been buffered.
    ///
    /// When the limit would be exceeded, `drain`/`sendFile` return
    /// `error.WriteFailed`; callers (`streamRemaining`) can then inspect
    /// `bytes_written` to distinguish "too large" from a real write error.
    const CountingWriter = struct {
        inner: *std.Io.Writer.Allocating,
        bytes_written: u64,
        max_bytes: u64,
        limit_exceeded: bool,
        progress: ?ProgressCallback,
        content_length: ?u64,
        writer: std.Io.Writer = .{
            .buffer = &.{},
            .vtable = &.{
                .drain = drain,
                .sendFile = sendFile,
                .flush = flush,
                .rebase = rebase,
            },
        },

        fn report(self: *CountingWriter) void {
            if (self.progress) |p| p.report(self.bytes_written, self.content_length);
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *CountingWriter = @fieldParentPtr("writer", w);
            const n = self.inner.writer.vtable.drain(&self.inner.writer, data, splat) catch
                return error.WriteFailed;
            self.bytes_written += n;
            self.report();
            if (self.bytes_written > self.max_bytes) {
                self.limit_exceeded = true;
                return error.WriteFailed;
            }
            return n;
        }

        fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
            const self: *CountingWriter = @fieldParentPtr("writer", w);
            const n = self.inner.writer.vtable.sendFile(&self.inner.writer, file_reader, limit) catch |e| return e;
            self.bytes_written += n;
            self.report();
            if (self.bytes_written > self.max_bytes) {
                self.limit_exceeded = true;
                return error.WriteFailed;
            }
            return n;
        }

        fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *CountingWriter = @fieldParentPtr("writer", w);
            return self.inner.writer.vtable.flush(&self.inner.writer);
        }

        fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
            const self: *CountingWriter = @fieldParentPtr("writer", w);
            return self.inner.writer.vtable.rebase(&self.inner.writer, preserve, capacity);
        }
    };

    fn doGet(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !Response {
        return self.doGetWithRetry(url, extra_headers, MAX_METADATA_BYTES, null);
    }

    fn doGetWithRetry(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        max_bytes: usize,
        progress: ?ProgressCallback,
    ) !Response {
        var attempt: usize = 0;
        while (true) {
            const result = self.doGetLimited(url, extra_headers, max_bytes, progress);
            if (result) |resp| {
                // Retry on transient server errors
                if (resp.status == 429 or resp.status == 503 or resp.status == 504) {
                    resp.allocator.free(resp.body);
                    if (attempt < MAX_RETRIES) {
                        std.Io.sleep(io_mod.ctx(), std.Io.Duration.fromNanoseconds(@intCast(RETRY_DELAYS_MS[attempt] * std.time.ns_per_ms)), .awake) catch {};
                        attempt += 1;
                        continue;
                    }
                }
                return resp;
            } else |err| {
                // Retry on connection errors
                if (attempt < MAX_RETRIES) {
                    std.Io.sleep(io_mod.ctx(), std.Io.Duration.fromNanoseconds(@intCast(RETRY_DELAYS_MS[attempt] * std.time.ns_per_ms)), .awake) catch {};
                    attempt += 1;
                    continue;
                }
                return err;
            }
        }
    }

    fn doGetLimited(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        max_bytes: usize,
        progress: ?ProgressCallback,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        // 32 KiB header buffer — see comment in `head()`. Blob
        // redirects from GHCR (Azure CDN signed URLs) routinely push
        // past the old 8 KiB budget.
        var redirect_buf: [32 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        const status: u16 = @intFromEnum(response.head.status);

        // Content-Length from HTTP headers (may be null for chunked transfer).
        // Note: this reflects the *compressed* size when content-encoding is set.
        const content_length: ?u64 = response.head.content_length;

        // Read response body with decompression (servers may send gzip).
        // Enforce MAX_RESPONSE_BYTES to prevent OOM from oversized responses.
        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();

        // Pooled decompression windows (see HttpClient.zstd_window / flate_window).
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.getZstdWindow(),
            .deflate, .gzip => try self.getFlateWindow(),
            .compress => return error.ReadFailed,
        };

        var transfer_buffer: [16384]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        // Timeout watchdog: closes the underlying connection if the read
        // stalls beyond the deadline. This is the only reliable way to
        // abort a blocking read call.
        //
        // `request_done` is a one-shot event so the main thread can wake
        // the watchdog immediately on completion. The previous polling
        // implementation slept in 1 s ticks and could stall `join()` by
        // up to a full second per request — that was the entire warm
        // install floor (see docs/perf/results.md).
        const effective_timeout = if (max_bytes > MAX_METADATA_BYTES) BLOB_TIMEOUT_NS else self.timeout_ns;
        var request_done: std.Io.Event = .unset;
        const watchdog = std.Thread.spawn(.{}, watchdogFn, .{
            &request_done,
            effective_timeout,
            &req,
        }) catch null;
        defer {
            request_done.set(io_mod.ctx());
            if (watchdog) |w| w.join();
        }

        // Read the full response body through a CountingWriter that enforces
        // `max_bytes` per-write. This rejects oversized responses mid-stream
        // instead of after the whole body is already buffered (and the old
        // code's only check was post-hoc, which defeats the purpose on a
        // 2 GB/500 MB body).
        var counting = CountingWriter{
            .inner = &body_writer,
            .bytes_written = 0,
            .max_bytes = max_bytes,
            .limit_exceeded = false,
            .progress = progress,
            .content_length = content_length,
        };
        _ = body_reader.streamRemaining(&counting.writer) catch |e| switch (e) {
            error.WriteFailed => {
                request_done.set(io_mod.ctx());
                if (counting.limit_exceeded) return error.ResponseTooLarge;
                return error.ReadFailed;
            },
            error.ReadFailed => {
                request_done.set(io_mod.ctx());
                return error.ReadFailed;
            },
        };

        request_done.set(io_mod.ctx());
        if (counting.limit_exceeded) return error.ResponseTooLarge;

        const body = try body_writer.toOwnedSlice();

        return .{
            .status = status,
            .body = body,
            .allocator = self.allocator,
        };
    }

    /// Watchdog thread: waits until either the main thread signals
    /// `request_done` (request finished normally) or the timeout elapses.
    /// On timeout, marks the connection dead AND hard-shuts-down the
    /// underlying TCP socket so any in-flight `readv` / `writev` on
    /// the main thread returns immediately.
    ///
    /// **Important:** setting `conn.closing = true` alone is not
    /// enough to interrupt a blocked read. That flag only influences
    /// the *next* read — a `readv` already parked in the kernel
    /// waiting on TLS bytes stays parked indefinitely. This used to
    /// hang malt for minutes if a dep formula fetch hit a stalled
    /// TLS connection (observed once during cold-ffmpeg bench runs).
    /// `posix.shutdown(fd, .both)` forces the kernel to wake the
    /// blocked syscall with an error, unblocking the main thread.
    ///
    /// Uses `ResetEvent.timedWait` so the main thread can wake us
    /// immediately on successful completion — no polling overhead.
    fn watchdogFn(
        request_done: *std.Io.Event,
        timeout_ns: u64,
        req: *std.http.Client.Request,
    ) void {
        const io = io_mod.ctx();
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)),
            .clock = .awake,
        } };
        request_done.waitTimeout(io, timeout) catch |err| switch (err) {
            error.Timeout => {
                if (req.connection) |conn| {
                    conn.closing = true;
                    const fd = conn.stream_reader.stream.socket.handle;
                    _ = std.c.shutdown(fd, 2); // SHUT_RDWR
                }
            },
            else => {},
        };
    }
};

/// Thread-safe pool of `HttpClient` instances with borrow/return
/// semantics. Workers call `acquire()` to get exclusive access to an
/// idle client, use it synchronously, then call `release()` so another
/// worker can take it.
///
/// Why a pool: `std.http.Client` is *not* thread-safe across
/// concurrent calls, but creating a fresh one per request pays the
/// TLS context + cert store + connection setup cost every time. On a
/// cold `ffmpeg` install that was ~15 HttpClient creations back to
/// back (formula fetches + GHCR token + 12 blob downloads), each
/// paying its own handshake. A 4-slot pool keeps per-connection
/// reuse for the hot phase while preserving the no-sharing invariant.
///
/// All methods are safe to call from multiple threads.
pub const HttpClientPool = struct {
    allocator: std.mem.Allocator,
    clients: []HttpClient,
    busy: []bool,
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,

    pub fn init(allocator: std.mem.Allocator, size: usize) !HttpClientPool {
        const clients = try allocator.alloc(HttpClient, size);
        errdefer allocator.free(clients);
        const busy = try allocator.alloc(bool, size);
        errdefer allocator.free(busy);
        @memset(busy, false);
        for (clients) |*c| c.* = HttpClient.init(allocator);
        return .{
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

    /// Block until an idle client is available, mark it busy, return
    /// a pointer the caller can use exclusively until `release`.
    pub fn acquire(self: *HttpClientPool) *HttpClient {
        const io = io_mod.ctx();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            for (self.busy, 0..) |b, i| {
                if (!b) {
                    self.busy[i] = true;
                    return &self.clients[i];
                }
            }
            self.cond.waitUncancelable(io, &self.mutex);
        }
    }

    /// Return a previously-acquired client to the pool. The pointer
    /// must have come from `acquire` on the same pool; calling with
    /// a foreign pointer is a programmer error.
    pub fn release(self: *HttpClientPool, client: *HttpClient) void {
        const io = io_mod.ctx();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const base = @intFromPtr(self.clients.ptr);
        const addr = @intFromPtr(client);
        const idx = (addr - base) / @sizeOf(HttpClient);
        std.debug.assert(idx < self.clients.len);
        self.busy[idx] = false;
        self.cond.signal(io);
    }
};
