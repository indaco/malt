const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const io_mod = @import("../ui/io.zig");

pub const DownloadError = error{
    Timeout,
    ConnectionReset,
    HttpClientError,
    HttpServerError,
    RateLimited,
    TlsDowngradeRefused,
    ResponseTooLarge,
    ReadFailed,
};

pub const DownloadDiagnostic = struct {
    status: ?u16,
    url: []const u8,
    bytes_read: u64,
    err: DownloadError,

    pub fn isPermanent(self: DownloadDiagnostic) bool {
        return switch (self.err) {
            error.HttpClientError => blk: {
                const s = self.status orelse break :blk false;
                break :blk s == 404 or s == 410;
            },
            error.TlsDowngradeRefused, error.ResponseTooLarge => true,
            else => false,
        };
    }
};

pub fn classifyStatus(status: u16) ?DownloadError {
    if (status >= 200 and status < 400) return null;
    if (status == 429) return error.RateLimited;
    if (status >= 400 and status < 500) return error.HttpClientError;
    if (status >= 500) return error.HttpServerError;
    return null;
}

pub fn isTransientError(err: DownloadError) bool {
    return switch (err) {
        error.Timeout, error.ConnectionReset, error.HttpServerError, error.RateLimited, error.ReadFailed => true,
        error.HttpClientError, error.TlsDowngradeRefused, error.ResponseTooLarge => false,
    };
}

/// Read-timeout in ns scaled by Content-Length; floor 30 s at 64 KiB/s.
pub fn scaledTimeoutNs(content_length: ?u64) u64 {
    const floor_ns: u64 = 30 * std.time.ns_per_s;
    const cl = content_length orelse return floor_ns;
    const min_bandwidth: u64 = 64 * 1024; // 64 KiB/s
    const transfer_ns = (cl / min_bandwidth) * std.time.ns_per_s;
    return @max(floor_ns, transfer_ns);
}

/// Optional progress callback for long downloads (post-decompression bytes).
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

/// True if the URI scheme is exactly "https" (ascii case-insensitive).
pub fn schemeIsHttps(scheme: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scheme, "https");
}

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    /// Per-request timeout in nanoseconds. Default: 30 seconds.
    timeout_ns: u64 = default_timeout_ns,

    /// Reused across requests; each HttpClient is borrowed single-threaded
    /// from a pool, so no concurrent access.
    zstd_window: ?[]u8 = null,
    flate_window: ?[]u8 = null,

    const default_timeout_ns: u64 = 30 * std.time.ns_per_s;
    /// Blob downloads (bottles, cask DMGs) get a much longer timeout.
    const blob_timeout_ns: u64 = 600 * std.time.ns_per_s; // 10 minutes

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

    /// GET request; auto-injects HOMEBREW_GITHUB_API_TOKEN as Authorization
    /// for GitHub/Homebrew hosts. Caller owns the returned `Response`.
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

    /// GET with extra headers under `max_blob_bytes`. Caller owns `Response`.
    pub fn getWithHeaders(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        progress: ?ProgressCallback,
    ) !Response {
        return self.doGetWithRetry(url, extra_headers, max_blob_bytes, progress);
    }

    /// Perform a HEAD request and return only the HTTP status code.
    pub fn head(self: *HttpClient, url: []const u8) !u16 {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.HEAD, uri, .{
            .extra_headers = &.{},
        });
        defer req.deinit();

        try req.sendBodiless();

        // 32 KiB — GHCR's multi-scope token + signed-URL redirects exceed
        // the 8 KiB default and tripped `HeaderBufferTooSmall`.
        var redirect_buf: [32 * 1024]u8 = undefined;
        const response = try req.receiveHead(&redirect_buf);

        return @intFromEnum(response.head.status);
    }

    pub const HeadResolved = struct {
        final_url: []const u8,
        content_disposition: ?[]const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *HeadResolved) void {
            self.allocator.free(self.final_url);
            if (self.content_disposition) |cd| self.allocator.free(cd);
        }

        /// Swap `final_url` to a fresh dupe of `new_url`. The old slice is
        /// only freed after the new dupe succeeds, so an OOM here leaves
        /// the struct's invariants intact for `deinit`.
        pub fn replaceFinalUrl(self: *HeadResolved, new_url: []const u8) !void {
            const next = try self.allocator.dupe(u8, new_url);
            self.allocator.free(self.final_url);
            self.final_url = next;
        }
    };

    const max_head_redirects = 5;

    /// HEAD with manual redirect follow — stdlib skips redirects on HEAD.
    pub fn headResolved(self: *HttpClient, url: []const u8) !HeadResolved {
        // Build the result eagerly so a single errdefer covers every dupe
        // inside the redirect loop; on success the caller takes ownership.
        var resolved: HeadResolved = .{
            .final_url = try self.allocator.dupe(u8, url),
            .content_disposition = null,
            .allocator = self.allocator,
        };
        errdefer resolved.deinit();

        for (0..max_head_redirects) |_| {
            const uri = std.Uri.parse(resolved.final_url) catch break;

            var req = self.client.request(.HEAD, uri, .{
                .extra_headers = &.{},
            }) catch break;
            defer req.deinit();

            req.sendBodiless() catch break;

            var redirect_buf: [32 * 1024]u8 = undefined;
            const response = req.receiveHead(&redirect_buf) catch break;

            if (resolved.content_disposition == null) {
                if (response.head.content_disposition) |cd| {
                    resolved.content_disposition = try self.allocator.dupe(u8, cd);
                }
            }

            const status: u16 = @intFromEnum(response.head.status);
            if (status >= 301 and status <= 308) {
                if (response.head.location) |loc| {
                    try resolved.replaceFinalUrl(loc);
                    continue;
                }
            }
            break;
        }

        return resolved;
    }

    /// Metadata cap (formula.json is ~25 MB; 50 MB gives headroom).
    const max_metadata_bytes: usize = 50 * 1024 * 1024;

    /// Bottle responses can be 500+ MB. We cap at 2 GB to prevent true OOM.
    const max_blob_bytes: usize = 2 * 1024 * 1024 * 1024;

    // ---- internal helper ----

    const max_retries = 3;
    const retry_delays_ms = [_]u64{ 1000, 2000, 4000 };

    /// Counts written bytes, enforces an upper bound mid-stream, and reports
    /// progress. On overflow `drain`/`sendFile` return `error.WriteFailed`
    /// and callers distinguish via `bytes_written` vs `limit_exceeded`.
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
        return self.doGetWithRetry(url, extra_headers, max_metadata_bytes, null);
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
                if (classifyStatus(resp.status)) |dl_err| {
                    if (isTransientError(dl_err) and attempt < max_retries) {
                        resp.allocator.free(resp.body);
                        std.Io.sleep(io_mod.ctx(), std.Io.Duration.fromNanoseconds(@intCast(retry_delays_ms[attempt] * std.time.ns_per_ms)), .awake) catch {};
                        attempt += 1;
                        continue;
                    }
                }
                return resp;
            } else |err| {
                if (attempt < max_retries) {
                    std.Io.sleep(io_mod.ctx(), std.Io.Duration.fromNanoseconds(@intCast(retry_delays_ms[attempt] * std.time.ns_per_ms)), .awake) catch {};
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
        const https_origin = schemeIsHttps(uri.scheme);

        var req = try self.client.request(.GET, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        // 32 KiB header buffer — see `head()`.
        var redirect_buf: [32 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Refuse https → http downgrade across 3xx — plaintext bodies are
        // a metadata-substitution vector even with stdlib header stripping.
        if (https_origin and !schemeIsHttps(req.uri.scheme))
            return error.TlsDowngradeRefused;

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

        // Watchdog closes the socket on stall; one-shot `request_done`
        // wakes it immediately on success (previous 1 s polling stalled
        // `join()` and dominated the warm-install floor).
        const effective_timeout = if (max_bytes > max_metadata_bytes)
            @max(blob_timeout_ns, scaledTimeoutNs(content_length))
        else
            self.timeout_ns;
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

        // `CountingWriter` enforces `max_bytes` per-write so oversized bodies
        // are rejected mid-stream, not after buffering.
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

    /// On timeout, both flag the connection and `shutdown(.both)` the fd —
    /// setting `conn.closing` alone does not wake a `readv` already parked
    /// in the kernel, which hung malt for minutes on stalled TLS reads.
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

fn formatUri(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    const scheme = uri.scheme;
    const host = if (uri.host) |h| switch (h) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    } else "";
    const path = switch (uri.path) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    };
    const query = if (uri.query) |q| switch (q) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    } else null;
    const fragment = if (uri.fragment) |f| switch (f) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    } else null;

    if (fragment) |frag| {
        if (query) |q| {
            return std.fmt.allocPrint(allocator, "{s}://{s}{s}?{s}#{s}", .{ scheme, host, path, q, frag });
        }
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}#{s}", .{ scheme, host, path, frag });
    }
    if (query) |q| {
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}?{s}", .{ scheme, host, path, q });
    }
    return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ scheme, host, path });
}

/// Thread-safe borrow/return pool of `HttpClient`s. `std.http.Client` is
/// not thread-safe, but per-request construction pays the full TLS
/// handshake every time; pooling preserves no-sharing while reusing
/// connections across the hot phase of an install.
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

    /// Block until idle, mark busy, return exclusive pointer until `release`.
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

    /// Return an acquired client; foreign pointers are a programmer error.
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
