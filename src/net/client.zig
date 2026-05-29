const std = @import("std");

pub const DownloadError = error{
    Timeout,
    ConnectionReset,
    HttpClientError,
    HttpServerError,
    RateLimited,
    TlsDowngradeRefused,
    ResponseTooLarge,
    ReadFailed,
    /// The watchdog could not be set up (pipe(2) or Thread.spawn failed).
    /// Without the watchdog a stalled download has no fail-fast, so we
    /// surface the error rather than silently degrade.
    WatchdogSpawnFailed,
    /// Offline mode active and no cached body to serve. Non-transient so
    /// retry-with-backoff bails immediately instead of waiting out the
    /// network on a guaranteed miss.
    OfflineRequired,
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
        error.Timeout, error.ConnectionReset, error.HttpServerError, error.RateLimited, error.ReadFailed, error.WatchdogSpawnFailed => true,
        error.HttpClientError, error.TlsDowngradeRefused, error.ResponseTooLarge, error.OfflineRequired => false,
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

/// Idle-timeout default + clamp range. The whole-transfer deadline
/// (`scaledTimeoutNs`) only fires when the projected transfer time
/// elapses, so a 0 B/s mid-transfer stall waits ~13 min for a 50 MB
/// bottle, ~2 h for a 500 MB one. The idle watchdog is the fail-fast
/// counterpart: bytes haven't advanced in `idle_timeout_ns` → kill.
const default_idle_timeout_ns: u64 = 30 * std.time.ns_per_s;
const min_idle_timeout_secs: u32 = 5;
const max_idle_timeout_secs: u32 = 600;

/// Parse `MALT_HTTP_IDLE_TIMEOUT_SECS`. Empty/garbage/null falls back
/// to the default; the clamp keeps a typo from disabling the watchdog
/// (`0`) or from setting it absurdly long.
pub fn idleTimeoutNsFromEnv(raw: ?[]const u8) u64 {
    const r = raw orelse return default_idle_timeout_ns;
    const trimmed = std.mem.trim(u8, r, " \t");
    if (trimmed.len == 0) return default_idle_timeout_ns;
    const parsed = std.fmt.parseInt(u32, trimmed, 10) catch return default_idle_timeout_ns;
    const clamped = std.math.clamp(parsed, min_idle_timeout_secs, max_idle_timeout_secs);
    return @as(u64, clamped) * std.time.ns_per_s;
}

/// Watchdog fires when *either* deadline is breached, or when an
/// external `cancelled` signal asks us to give up early — e.g. SIGINT
/// during the post-dispatch update probe. Pure so the policy is
/// unit-testable without real sockets / threads.
pub fn shouldFireIdleWatchdog(
    idle_elapsed_ns: u64,
    total_elapsed_ns: u64,
    idle_limit_ns: u64,
    total_limit_ns: u64,
    cancelled: bool,
) bool {
    if (cancelled) return true;
    return idle_elapsed_ns >= idle_limit_ns or total_elapsed_ns >= total_limit_ns;
}

/// Self-pipe wake mechanism for the watchdog. Replaces std.Io.Event,
/// whose wait can park indefinitely on Darwin under contention with a
/// sibling thread holding a socket read - the failure mode that produced
/// hung bottle downloads. `signal` closes the write end so the watchdog's
/// poll(2) on the read end wakes via POLLHUP without needing an extra
/// write syscall and without a pipe-full corner case.
const Wake = struct {
    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t,
    write_closed: bool,

    fn init() error{WatchdogSpawnFailed}!Wake {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.WatchdogSpawnFailed;
        return .{ .read_fd = fds[0], .write_fd = fds[1], .write_closed = false };
    }

    /// Idempotent. Caller-owned single-thread access; the watchdog only
    /// reads from the read end, never closes either end.
    fn signal(self: *Wake) void {
        if (!self.write_closed) {
            _ = std.c.close(self.write_fd);
            self.write_closed = true;
        }
    }

    fn deinit(self: *Wake) void {
        self.signal();
        _ = std.c.close(self.read_fd);
    }
};

/// Watchdog tick loop, pure of any `std.http` coupling so it's testable
/// without a live request. Returns true iff a deadline (or cancel) tripped
/// and the caller should shut the connection down; false iff `wake_fd`
/// became readable / POLLHUP-ed first (success path).
fn watchdogLoop(
    io: std.Io,
    wake_fd: std.posix.fd_t,
    bytes_progress: *std.atomic.Value(u64),
    idle_timeout_ns: u64,
    total_timeout_ns: u64,
    cancel: ?*const fn () bool,
) bool {
    const start_ns: u64 = @intCast(std.Io.Clock.real.now(io).toNanoseconds());
    var last_seen_bytes: u64 = bytes_progress.load(.acquire);
    var last_progress_ns: u64 = start_ns;
    // Quarter of the smallest deadline, capped at 5 s, floored at
    // 100 ms - keeps Ctrl-C snappy on a sub-second probe without
    // spinning on a multi-minute blob download.
    const tick_ns: u64 = @max(
        @min(@min(idle_timeout_ns, total_timeout_ns) / 4, 5 * std.time.ns_per_s),
        100 * std.time.ns_per_ms,
    );
    const tick_ms: i32 = @intCast(tick_ns / std.time.ns_per_ms);

    while (true) {
        var pfds = [_]std.posix.pollfd{.{
            .fd = wake_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        // poll(2) is a direct kernel syscall - its deadline behaviour on
        // Darwin is field-tested. EINTR is retried inside std.posix.poll.
        const n = std.posix.poll(&pfds, tick_ms) catch return false;
        if (n > 0) return false; // POLLIN or POLLHUP both clear revents

        const cur_bytes = bytes_progress.load(.acquire);
        const now_ns: u64 = @intCast(std.Io.Clock.real.now(io).toNanoseconds());
        if (cur_bytes > last_seen_bytes) {
            last_seen_bytes = cur_bytes;
            last_progress_ns = now_ns;
        }
        const idle_elapsed = now_ns - last_progress_ns;
        const total_elapsed = now_ns - start_ns;
        const cancelled = if (cancel) |fp| fp() else false;
        if (shouldFireIdleWatchdog(idle_elapsed, total_elapsed, idle_timeout_ns, total_timeout_ns, cancelled)) {
            return true;
        }
    }
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

/// Result of `HttpClient.getConditional`. `not_modified` is true iff
/// the server answered 304 — `body` is empty in that case and the
/// caller can keep using the cached payload. `etag`, when set, is the
/// server's current ETag (sent on both 200 and 304); callers persist
/// it so the next round can short-circuit again.
pub const ConditionalResponse = struct {
    status: u16,
    not_modified: bool,
    body: []const u8,
    etag: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ConditionalResponse) void {
        self.allocator.free(self.body);
        if (self.etag) |e| self.allocator.free(e);
    }
};

/// Find the `ETag` value in a parsed `Response.Head.bytes` buffer.
/// Returns a slice borrowed from `bytes` (caller dupes if it needs to
/// outlive the response). GitHub sends weak ETags as `W/"abc"` — the
/// `W/` prefix is preserved verbatim because the server compares the
/// `If-None-Match` value textually and stripping it breaks the 304
/// short-circuit.
pub fn extractEtagFromHead(bytes: []const u8) ?[]const u8 {
    var it = std.http.HeaderIterator.init(bytes);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "etag")) return h.value;
    }
    return null;
}

/// True if the URI scheme is exactly "https" (ascii case-insensitive).
pub fn schemeIsHttps(scheme: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scheme, "https");
}

pub const HttpClient = struct {
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    client: std.http.Client,

    /// Per-request timeout in nanoseconds. Default: 30 seconds.
    timeout_ns: u64 = default_timeout_ns,

    /// Optional cancellation predicate polled on every watchdog tick.
    /// Lets best-effort callers (e.g. the post-dispatch update probe)
    /// short-circuit a blackholed read on Ctrl-C without coupling
    /// `net/client` to the SIGINT mechanism the caller chose.
    cancel: ?*const fn () bool = null,

    /// When true, `get` / `getWithHeaders` / `head` / `headResolved`
    /// short-circuit with `error.OfflineRequired` before any DNS / TCP
    /// work. cli/ call sites set this from `ctx.offline` so a user on a
    /// plane fails fast instead of waiting for connect timeouts.
    offline: bool = false,

    /// Reused across requests; each HttpClient is borrowed single-threaded
    /// from a pool, so no concurrent access.
    zstd_window: ?[]u8 = null,
    flate_window: ?[]u8 = null,

    const default_timeout_ns: u64 = 30 * std.time.ns_per_s;
    /// Blob downloads (bottles, cask DMGs) get a much longer timeout.
    const blob_timeout_ns: u64 = 600 * std.time.ns_per_s; // 10 minutes

    pub fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator) HttpClient {
        var c: std.http.Client = .{ .allocator = allocator, .io = io };
        return initWith(&c, io, environ, allocator);
    }

    /// Injection seam for offline tests: takes an externally-built
    /// `std.http.Client` (e.g. pointed at a localhost `std.http.Server`)
    /// so HTTP-using commands run without a process-level network mock.
    /// The client is copied in and owned thereafter — `deinit` frees it,
    /// so callers must not deinit the passed-in client separately.
    pub fn initWith(
        client: *std.http.Client,
        io: std.Io,
        environ: std.process.Environ,
        allocator: std.mem.Allocator,
    ) HttpClient {
        return .{
            .io = io,
            .environ = environ,
            .allocator = allocator,
            .client = client.*,
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
        if (self.offline) return error.OfflineRequired;
        if (std.process.Environ.getPosix(self.environ, "HOMEBREW_GITHUB_API_TOKEN")) |token| {
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
        if (self.offline) return error.OfflineRequired;
        return self.doGetWithRetry(url, extra_headers, max_blob_bytes, progress);
    }

    /// Perform a HEAD request and return only the HTTP status code.
    pub fn head(self: *HttpClient, url: []const u8) !u16 {
        if (self.offline) return error.OfflineRequired;
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

    /// Conditional GET — sends `If-None-Match: <etag>` when `if_none_match`
    /// is non-null and returns a `ConditionalResponse` that surfaces the
    /// server's ETag plus a `not_modified` flag when the server answered
    /// 304. Caller passes any extra headers (e.g. `Authorization`); the
    /// `If-None-Match` header is prepended internally. Caller owns the
    /// returned `ConditionalResponse`.
    pub fn getConditional(
        self: *HttpClient,
        url: []const u8,
        if_none_match: ?[]const u8,
        extra_headers: []const std.http.Header,
    ) !ConditionalResponse {
        if (self.offline) return error.OfflineRequired;

        // Stack-buffered header list: today's only callers add at most
        // `If-None-Match` + `Authorization`. Bump if a real caller exceeds.
        var hdr_buf: [8]std.http.Header = undefined;
        var hdr_len: usize = 0;
        if (if_none_match) |inm| {
            hdr_buf[hdr_len] = .{ .name = "If-None-Match", .value = inm };
            hdr_len += 1;
        }
        for (extra_headers) |h| {
            std.debug.assert(hdr_len < hdr_buf.len);
            hdr_buf[hdr_len] = h;
            hdr_len += 1;
        }
        return self.doGetConditionalWithRetry(url, hdr_buf[0..hdr_len]);
    }

    /// HEAD with manual redirect follow — stdlib skips redirects on HEAD.
    pub fn headResolved(self: *HttpClient, url: []const u8) !HeadResolved {
        if (self.offline) return error.OfflineRequired;
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
    /// `bytes_written` is atomic so the idle watchdog (a separate thread)
    /// can sample it on each tick without a lock.
    const CountingWriter = struct {
        inner: *std.Io.Writer.Allocating,
        bytes_written: std.atomic.Value(u64),
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

        fn report(self: *CountingWriter, total: u64) void {
            if (self.progress) |p| p.report(total, self.content_length);
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *CountingWriter = @fieldParentPtr("writer", w);
            const n = self.inner.writer.vtable.drain(&self.inner.writer, data, splat) catch
                return error.WriteFailed;
            const total = self.bytes_written.fetchAdd(n, .release) + n;
            self.report(total);
            if (total > self.max_bytes) {
                self.limit_exceeded = true;
                return error.WriteFailed;
            }
            return n;
        }

        fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
            const self: *CountingWriter = @fieldParentPtr("writer", w);
            const n = self.inner.writer.vtable.sendFile(&self.inner.writer, file_reader, limit) catch |e| return e;
            const total = self.bytes_written.fetchAdd(n, .release) + n;
            self.report(total);
            if (total > self.max_bytes) {
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

    /// Read a response body with the same decompress + idle/total
    /// watchdog + size cap that the legacy `doGetLimited` path uses.
    /// Both the generic GET and the conditional GET converge here so
    /// the single transport policy is enforced in one place — only the
    /// `total_timeout_ns` differs between callers (blob downloads scale
    /// it from `content_length`; metadata reads pin it to `self.timeout_ns`).
    fn readResponseBody(
        self: *HttpClient,
        req: *std.http.Client.Request,
        response: *std.http.Client.Response,
        max_bytes: usize,
        progress: ?ProgressCallback,
        total_timeout_ns: u64,
    ) !([]const u8) {
        const content_length: ?u64 = response.head.content_length;

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.getZstdWindow(),
            .deflate, .gzip => try self.getFlateWindow(),
            .compress => return error.ReadFailed,
        };

        var transfer_buffer: [16384]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        var counting = CountingWriter{
            .inner = &body_writer,
            .bytes_written = std.atomic.Value(u64).init(0),
            .max_bytes = max_bytes,
            .limit_exceeded = false,
            .progress = progress,
            .content_length = content_length,
        };

        const idle_timeout = idleTimeoutNsFromEnv(
            std.process.Environ.getPosix(self.environ, "MALT_HTTP_IDLE_TIMEOUT_SECS"),
        );
        var wake = try Wake.init();
        const watchdog = std.Thread.spawn(.{}, watchdogFn, .{
            self.io,
            wake.read_fd,
            &counting.bytes_written,
            idle_timeout,
            total_timeout_ns,
            req,
            self.cancel,
        }) catch {
            wake.deinit();
            return error.WatchdogSpawnFailed;
        };
        defer {
            wake.signal();
            watchdog.join();
            wake.deinit();
        }
        _ = body_reader.streamRemaining(&counting.writer) catch |e| switch (e) {
            error.WriteFailed => {
                if (counting.limit_exceeded) return error.ResponseTooLarge;
                return error.ReadFailed;
            },
            error.ReadFailed => return error.ReadFailed,
        };

        if (counting.limit_exceeded) return error.ResponseTooLarge;

        return try body_writer.toOwnedSlice();
    }

    /// Cancellable backoff between retry attempts. Common to every
    /// retry loop so a Ctrl-C during the wait surfaces immediately
    /// instead of being swallowed by std.Io.sleep's silent return.
    fn retrySleep(self: *HttpClient, attempt: usize) error{Canceled}!void {
        std.Io.sleep(
            self.io,
            std.Io.Duration.fromNanoseconds(@intCast(retry_delays_ms[attempt] * std.time.ns_per_ms)),
            .awake,
        ) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
        };
    }

    fn doGetConditionalWithRetry(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !ConditionalResponse {
        var attempt: usize = 0;
        while (true) {
            const result = self.doGetConditionalOnce(url, extra_headers);
            if (result) |resp| {
                if (classifyStatus(resp.status)) |dl_err| {
                    if (isTransientError(dl_err) and attempt < max_retries) {
                        var r = resp;
                        r.deinit();
                        try self.retrySleep(attempt);
                        attempt += 1;
                        continue;
                    }
                }
                return resp;
            } else |err| {
                if (attempt < max_retries) {
                    try self.retrySleep(attempt);
                    attempt += 1;
                    continue;
                }
                return err;
            }
        }
    }

    fn doGetConditionalOnce(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !ConditionalResponse {
        const uri = try std.Uri.parse(url);
        const https_origin = schemeIsHttps(uri.scheme);

        var req = try self.client.request(.GET, uri, .{ .extra_headers = extra_headers });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [32 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (https_origin and !schemeIsHttps(req.uri.scheme))
            return error.TlsDowngradeRefused;

        const status: u16 = @intFromEnum(response.head.status);
        // Etag is borrowed from response.head.bytes; dupe before the head
        // buffer is dropped on function exit.
        const etag_owned: ?[]const u8 = if (extractEtagFromHead(response.head.bytes)) |e|
            try self.allocator.dupe(u8, e)
        else
            null;
        errdefer if (etag_owned) |e| self.allocator.free(e);

        // 304 has no body per HTTP spec — return immediately with an
        // empty owned slice so deinit's `free(body)` stays uniform.
        if (status == 304) {
            const empty = try self.allocator.alloc(u8, 0);
            return .{
                .status = status,
                .not_modified = true,
                .body = empty,
                .etag = etag_owned,
                .allocator = self.allocator,
            };
        }

        // Conditional GETs target tiny JSON, never blobs — pin both
        // size cap and total timeout to the metadata constants.
        const body = try self.readResponseBody(&req, &response, max_metadata_bytes, null, self.timeout_ns);
        return .{
            .status = status,
            .not_modified = false,
            .body = body,
            .etag = etag_owned,
            .allocator = self.allocator,
        };
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
                        // Cancellation is single-shot per task in std.Io —
                        // swallowing it here means the caller's stop signal
                        // is consumed by the backoff and never reaches the
                        // next request, so propagate it as the result.
                        std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(@intCast(retry_delays_ms[attempt] * std.time.ns_per_ms)), .awake) catch |e| switch (e) {
                            error.Canceled => return error.Canceled,
                        };
                        attempt += 1;
                        continue;
                    }
                }
                return resp;
            } else |err| {
                if (attempt < max_retries) {
                    std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(@intCast(retry_delays_ms[attempt] * std.time.ns_per_ms)), .awake) catch |e| switch (e) {
                        error.Canceled => return error.Canceled,
                    };
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

        // Blob downloads scale the total deadline from the projected
        // transfer time; metadata reads keep the per-request constant.
        // Idle-timeout backstop lives inside `readResponseBody`.
        const total_timeout = if (max_bytes > max_metadata_bytes)
            @max(blob_timeout_ns, scaledTimeoutNs(response.head.content_length))
        else
            self.timeout_ns;
        const body = try self.readResponseBody(&req, &response, max_bytes, progress, total_timeout);

        return .{
            .status = status,
            .body = body,
            .allocator = self.allocator,
        };
    }

    /// On a fired deadline (or cancellation), shuts down the request's
    /// socket so a kernel-parked `readv` returns. Both `conn.closing` AND
    /// `shutdown(.both)` because setting closing alone does not wake a
    /// parked read - stalled TLS reads hung the previous single-deadline
    /// implementation.
    fn watchdogFn(
        io: std.Io,
        wake_fd: std.posix.fd_t,
        bytes_progress: *std.atomic.Value(u64),
        idle_timeout_ns: u64,
        total_timeout_ns: u64,
        req: *std.http.Client.Request,
        cancel: ?*const fn () bool,
    ) void {
        if (!watchdogLoop(io, wake_fd, bytes_progress, idle_timeout_ns, total_timeout_ns, cancel)) return;
        if (req.connection) |conn| {
            conn.closing = true;
            const fd = conn.stream_reader.stream.socket.handle;
            _ = std.c.shutdown(fd, std.posix.SHUT.RDWR);
        }
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

test "extractEtagFromHead: finds ETag header by exact name" {
    const bytes = "200 OK\r\nServer: github\r\nETag: \"abc123\"\r\nContent-Length: 0\r\n\r\n";
    const et = extractEtagFromHead(bytes);
    try std.testing.expectEqualStrings("\"abc123\"", et.?);
}

test "extractEtagFromHead: header lookup is case-insensitive" {
    // GitHub spells it `ETag`; reverse proxies sometimes downcase to `etag`.
    const bytes = "200 OK\r\netag: \"abc123\"\r\n\r\n";
    const et = extractEtagFromHead(bytes);
    try std.testing.expectEqualStrings("\"abc123\"", et.?);
}

test "extractEtagFromHead: preserves GitHub's weak-ETag W/ prefix verbatim" {
    // Stripping W/ would break the 304 path — GitHub compares textually.
    const bytes = "304 Not Modified\r\nETag: W/\"deadbeef\"\r\n\r\n";
    const et = extractEtagFromHead(bytes);
    try std.testing.expectEqualStrings("W/\"deadbeef\"", et.?);
}

test "extractEtagFromHead: returns null when ETag header is absent" {
    const bytes = "200 OK\r\nContent-Length: 0\r\n\r\n";
    try std.testing.expectEqual(@as(?[]const u8, null), extractEtagFromHead(bytes));
}

test "extractEtagFromHead: skips lookalikes (`If-None-Match`, prefix matches)" {
    const bytes = "200 OK\r\nIf-None-Match: \"req-side\"\r\nETagged: \"nope\"\r\n\r\n";
    try std.testing.expectEqual(@as(?[]const u8, null), extractEtagFromHead(bytes));
}

test "ConditionalResponse.deinit: frees body and etag together" {
    var cr: ConditionalResponse = .{
        .status = 200,
        .not_modified = false,
        .body = try std.testing.allocator.dupe(u8, "{}"),
        .etag = try std.testing.allocator.dupe(u8, "W/\"abc\""),
        .allocator = std.testing.allocator,
    };
    cr.deinit();
}

test "ConditionalResponse.deinit: tolerates null etag (server omitted the header)" {
    var cr: ConditionalResponse = .{
        .status = 200,
        .not_modified = false,
        .body = try std.testing.allocator.dupe(u8, "{}"),
        .etag = null,
        .allocator = std.testing.allocator,
    };
    cr.deinit();
}

test "ConditionalResponse.deinit: 304 path with empty body frees correctly" {
    var cr: ConditionalResponse = .{
        .status = 304,
        .not_modified = true,
        // 304 has no body but the wrapper still owns a (possibly empty) slice.
        .body = try std.testing.allocator.alloc(u8, 0),
        .etag = try std.testing.allocator.dupe(u8, "W/\"abc\""),
        .allocator = std.testing.allocator,
    };
    cr.deinit();
}

test "HttpClient.initWith: injected client is copied in, distinct from the struct allocator" {
    // Build the client with one allocator and pass a *different* one as the
    // struct allocator. The seam must keep the injected client's allocator
    // (proving it copied the client, not rebuilt it from the param) while the
    // struct's own allocator tracks the param.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const struct_alloc = arena.allocator();
    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.Options.debug_io };
    var http = HttpClient.initWith(&inner, std.Options.debug_io, std.process.Environ.empty, struct_alloc);
    defer http.deinit();
    try std.testing.expectEqual(std.testing.allocator.ptr, http.client.allocator.ptr);
    try std.testing.expectEqual(struct_alloc.ptr, http.allocator.ptr);
    try std.testing.expect(http.client.allocator.ptr != http.allocator.ptr);
}

test "HttpClient.initWith: preserves field defaults" {
    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.Options.debug_io };
    var http = HttpClient.initWith(&inner, std.Options.debug_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();
    try std.testing.expect(!http.offline);
    try std.testing.expectEqual(HttpClient.default_timeout_ns, http.timeout_ns);
    try std.testing.expectEqual(@as(?*const fn () bool, null), http.cancel);
    try std.testing.expectEqual(@as(?[]u8, null), http.zstd_window);
    try std.testing.expectEqual(@as(?[]u8, null), http.flate_window);
}

test "HttpClient.init: delegates to initWith without losing defaults" {
    // Pins the refactor: init now builds its own client and forwards to
    // initWith — the defaults the production path relies on must survive.
    var http = HttpClient.init(std.Options.debug_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();
    try std.testing.expect(!http.offline);
    try std.testing.expectEqual(HttpClient.default_timeout_ns, http.timeout_ns);
    try std.testing.expectEqual(std.testing.allocator.ptr, http.client.allocator.ptr);
}

test "HttpClient.offline defaults to false" {
    var http = HttpClient.init(std.Options.debug_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();
    try std.testing.expect(!http.offline);
}

test "HttpClient.get returns OfflineRequired when offline is set" {
    var http = HttpClient.init(std.Options.debug_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();
    http.offline = true;
    // Use a host that would 404/connect-refuse in the real world — the
    // gate must trip before any DNS / TCP work happens.
    try std.testing.expectError(error.OfflineRequired, http.get("https://example.invalid/x"));
}

test "HttpClient.getConditional returns OfflineRequired when offline is set" {
    var http = HttpClient.init(std.Options.debug_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();
    http.offline = true;
    try std.testing.expectError(
        error.OfflineRequired,
        http.getConditional("https://example.invalid/x", null, &.{}),
    );
}

test "HttpClient.head returns OfflineRequired when offline is set" {
    var http = HttpClient.init(std.Options.debug_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();
    http.offline = true;
    try std.testing.expectError(error.OfflineRequired, http.head("https://example.invalid/x"));
}

test "idleTimeoutNsFromEnv: null falls back to default" {
    try std.testing.expectEqual(default_idle_timeout_ns, idleTimeoutNsFromEnv(null));
}

test "idleTimeoutNsFromEnv: empty / whitespace falls back to default" {
    try std.testing.expectEqual(default_idle_timeout_ns, idleTimeoutNsFromEnv(""));
    try std.testing.expectEqual(default_idle_timeout_ns, idleTimeoutNsFromEnv("   "));
    try std.testing.expectEqual(default_idle_timeout_ns, idleTimeoutNsFromEnv("\t"));
}

test "idleTimeoutNsFromEnv: garbage falls back to default (typo can't disable watchdog)" {
    try std.testing.expectEqual(default_idle_timeout_ns, idleTimeoutNsFromEnv("nope"));
    try std.testing.expectEqual(default_idle_timeout_ns, idleTimeoutNsFromEnv("-1"));
    try std.testing.expectEqual(default_idle_timeout_ns, idleTimeoutNsFromEnv("9999999999999"));
}

test "idleTimeoutNsFromEnv: parses an in-range value" {
    try std.testing.expectEqual(@as(u64, 60) * std.time.ns_per_s, idleTimeoutNsFromEnv("60"));
    try std.testing.expectEqual(@as(u64, 120) * std.time.ns_per_s, idleTimeoutNsFromEnv("120"));
}

test "idleTimeoutNsFromEnv: clamps below floor (zero would silently disable)" {
    try std.testing.expectEqual(@as(u64, min_idle_timeout_secs) * std.time.ns_per_s, idleTimeoutNsFromEnv("0"));
    try std.testing.expectEqual(@as(u64, min_idle_timeout_secs) * std.time.ns_per_s, idleTimeoutNsFromEnv("1"));
}

test "idleTimeoutNsFromEnv: clamps above ceiling" {
    try std.testing.expectEqual(@as(u64, max_idle_timeout_secs) * std.time.ns_per_s, idleTimeoutNsFromEnv("99999"));
}

test "shouldFireIdleWatchdog: false when both elapsed below their limits and not cancelled" {
    try std.testing.expect(!shouldFireIdleWatchdog(10, 100, 30, 600, false));
    try std.testing.expect(!shouldFireIdleWatchdog(0, 0, 30, 600, false));
}

test "shouldFireIdleWatchdog: true when idle elapsed >= idle limit (mid-transfer stall)" {
    try std.testing.expect(shouldFireIdleWatchdog(30, 100, 30, 600, false));
    try std.testing.expect(shouldFireIdleWatchdog(31, 100, 30, 600, false));
}

test "shouldFireIdleWatchdog: true when total elapsed >= total limit (slow trickle backstop)" {
    try std.testing.expect(shouldFireIdleWatchdog(0, 600, 30, 600, false));
    try std.testing.expect(shouldFireIdleWatchdog(0, 9999, 30, 600, false));
}

test "shouldFireIdleWatchdog: cancellation fires regardless of elapsed time" {
    // SIGINT during a best-effort probe must short-circuit even when no
    // deadline has elapsed yet — otherwise Ctrl-C waits out the read.
    try std.testing.expect(shouldFireIdleWatchdog(0, 0, 30, 600, true));
    try std.testing.expect(shouldFireIdleWatchdog(1, 1, 999_999, 999_999, true));
}

// Patches an inner Io's vtable so `sleep` reports cancellation on the
// configured call index; non-canceled sleeps return immediately so the
// retry-table delays don't pad the test runtime. `cancel_at = 1` cancels
// the first sleep, `cancel_at = N` returns from the prior N-1 sleeps and
// trips the Nth.
const CancelSleepProbe = struct {
    var vtable: std.Io.VTable = undefined;
    var sleep_calls: usize = 0;
    var cancel_at: usize = 1;

    fn wrap(inner: std.Io, cancel_at_call: usize) std.Io {
        vtable = inner.vtable.*;
        vtable.sleep = sleepMaybeCanceled;
        sleep_calls = 0;
        cancel_at = cancel_at_call;
        return .{ .userdata = inner.userdata, .vtable = &vtable };
    }

    fn sleepMaybeCanceled(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
        sleep_calls += 1;
        if (sleep_calls >= cancel_at) return error.Canceled;
    }
};

test "doGetWithRetry surfaces sleep cancellation on the first backoff" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const cancel_io = CancelSleepProbe.wrap(threaded.io(), 1);

    var http = HttpClient.init(cancel_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    // 127.0.0.1:1 fast-fails with ECONNREFUSED so the retry-sleep is reached
    // on the first attempt; without the fix, every backoff swallows Canceled
    // and the call resolves with the connect error after burning all retries.
    const result = http.get("http://127.0.0.1:1/nothing-listens-here");
    try std.testing.expectError(error.Canceled, result);
    try std.testing.expectEqual(@as(usize, 1), CancelSleepProbe.sleep_calls);
}

test "doGetWithRetry surfaces sleep cancellation on a later backoff" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    // Cancel the third sleep — the prior two return normally, exercising
    // the retry counter alongside the catch arm so we know the propagation
    // isn't tied to attempt 0 only.
    const cancel_io = CancelSleepProbe.wrap(threaded.io(), 3);

    var http = HttpClient.init(cancel_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    const result = http.get("http://127.0.0.1:1/nothing-listens-here");
    try std.testing.expectError(error.Canceled, result);
    try std.testing.expectEqual(@as(usize, 3), CancelSleepProbe.sleep_calls);
}

// ── Wake + watchdogLoop: poll(2)-based watchdog wake mechanism ─────

test "Wake.signal: closing the write end produces POLLHUP on the read fd" {
    var wake = try Wake.init();
    defer wake.deinit();
    wake.signal();
    var pfds = [_]std.posix.pollfd{.{
        .fd = wake.read_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = try std.posix.poll(&pfds, 500);
    try std.testing.expect(n > 0);
    try std.testing.expect(pfds[0].revents != 0);
}

test "Wake.signal: idempotent" {
    var wake = try Wake.init();
    defer wake.deinit();
    wake.signal();
    wake.signal(); // second call must not double-close the fd
}

test "Wake without signal: poll on the read fd times out" {
    var wake = try Wake.init();
    defer wake.deinit();
    var pfds = [_]std.posix.pollfd{.{
        .fd = wake.read_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = try std.posix.poll(&pfds, 50);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "watchdogLoop: returns false when wake signalled before the first tick" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var wake = try Wake.init();
    defer wake.deinit();
    wake.signal();
    var bytes = std.atomic.Value(u64).init(0);
    const fired = watchdogLoop(io, wake.read_fd, &bytes, 1 * std.time.ns_per_s, 1 * std.time.ns_per_s, null);
    try std.testing.expect(!fired);
}

test "watchdogLoop: fires when idle deadline elapses with no progress" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var wake = try Wake.init();
    defer wake.deinit();
    var bytes = std.atomic.Value(u64).init(0);
    // idle=200 ms forces tick to floor (100 ms); loop fires on second tick.
    const fired = watchdogLoop(io, wake.read_fd, &bytes, 200 * std.time.ns_per_ms, 10 * std.time.ns_per_s, null);
    try std.testing.expect(fired);
}

test "watchdogLoop: fires when total deadline elapses even with progress" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var wake = try Wake.init();
    defer wake.deinit();
    // Bump bytes after start so idle keeps resetting; only total can fire.
    var bytes = std.atomic.Value(u64).init(1);
    const fired = watchdogLoop(io, wake.read_fd, &bytes, 10 * std.time.ns_per_s, 200 * std.time.ns_per_ms, null);
    try std.testing.expect(fired);
}

test "watchdogLoop: fires on cancellation predicate" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var wake = try Wake.init();
    defer wake.deinit();
    var bytes = std.atomic.Value(u64).init(0);
    const Stub = struct {
        fn cancel() bool {
            return true;
        }
    };
    const fired = watchdogLoop(io, wake.read_fd, &bytes, 10 * std.time.ns_per_s, 10 * std.time.ns_per_s, &Stub.cancel);
    try std.testing.expect(fired);
}
