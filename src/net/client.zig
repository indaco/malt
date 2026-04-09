const std = @import("std");

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

    const DEFAULT_TIMEOUT_NS: u64 = 30 * std.time.ns_per_s;
    /// Blob downloads (bottles, cask DMGs) get a much longer timeout.
    const BLOB_TIMEOUT_NS: u64 = 600 * std.time.ns_per_s; // 10 minutes

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Perform a GET request and return the response status and body.
    /// Automatically injects HOMEBREW_GITHUB_API_TOKEN as Authorization
    /// header for GitHub/Homebrew API requests when the env var is set.
    /// The caller owns the returned `Response` and must call `deinit` on it.
    pub fn get(self: *HttpClient, url: []const u8) !Response {
        if (std.posix.getenv("HOMEBREW_GITHUB_API_TOKEN")) |token| {
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
    ) !Response {
        return self.doGetWithRetry(url, extra_headers, MAX_BLOB_BYTES);
    }

    /// Perform a HEAD request and return only the HTTP status code.
    pub fn head(self: *HttpClient, url: []const u8) !u16 {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.HEAD, uri, .{
            .extra_headers = &.{},
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8 * 1024]u8 = undefined;
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

    fn doGet(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !Response {
        return self.doGetWithRetry(url, extra_headers, MAX_METADATA_BYTES);
    }

    fn doGetWithRetry(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        max_bytes: usize,
    ) !Response {
        var attempt: usize = 0;
        while (true) {
            const result = self.doGetLimited(url, extra_headers, max_bytes);
            if (result) |resp| {
                // Retry on transient server errors
                if (resp.status == 429 or resp.status == 503 or resp.status == 504) {
                    resp.allocator.free(resp.body);
                    if (attempt < MAX_RETRIES) {
                        std.Thread.sleep(RETRY_DELAYS_MS[attempt] * std.time.ns_per_ms);
                        attempt += 1;
                        continue;
                    }
                }
                return resp;
            } else |err| {
                // Retry on connection errors
                if (attempt < MAX_RETRIES) {
                    std.Thread.sleep(RETRY_DELAYS_MS[attempt] * std.time.ns_per_ms);
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
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        const status: u16 = @intFromEnum(response.head.status);

        // Read response body with decompression (servers may send gzip).
        // Enforce MAX_RESPONSE_BYTES to prevent OOM from oversized responses.
        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();

        // Allocate decompression buffers based on content encoding
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.ReadFailed,
        };
        defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);

        var transfer_buffer: [16384]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        // Timeout watchdog: closes the underlying connection if the read
        // stalls beyond the deadline. This is the only reliable way to
        // abort a blocking streamRemaining call.
        const effective_timeout = if (max_bytes > MAX_METADATA_BYTES) BLOB_TIMEOUT_NS else self.timeout_ns;
        var request_done = std.atomic.Value(bool).init(false);
        const watchdog = std.Thread.spawn(.{}, watchdogFn, .{
            &request_done,
            effective_timeout,
            &req,
        }) catch null;
        defer {
            request_done.store(true, .release);
            if (watchdog) |w| w.join();
        }

        // Read the full response body. streamRemaining handles internal
        // buffering and decompression (gzip/deflate/zstd) correctly.
        const total_read = body_reader.streamRemaining(&body_writer.writer) catch |e| switch (e) {
            error.WriteFailed => return error.ReadFailed,
            error.ReadFailed => return error.ReadFailed,
        };

        // Signal watchdog that we finished before timeout
        request_done.store(true, .release);

        // If we read more than the limit, the response is too large.
        if (total_read >= max_bytes) return error.ResponseTooLarge;

        const body = try body_writer.toOwnedSlice();

        return .{
            .status = status,
            .body = body,
            .allocator = self.allocator,
        };
    }

    /// Watchdog thread: sleeps for the timeout duration, then aborts the
    /// request by closing its connection. This unblocks streamRemaining.
    /// Watchdog thread: sleeps for the timeout duration, then marks
    /// the connection as closing. This causes the next read to fail,
    /// unblocking a stalled streamRemaining call.
    fn watchdogFn(
        request_done: *std.atomic.Value(bool),
        timeout_ns: u64,
        req: *std.http.Client.Request,
    ) void {
        var elapsed: u64 = 0;
        const interval: u64 = 1 * std.time.ns_per_s;
        while (elapsed < timeout_ns) {
            if (request_done.load(.acquire)) return;
            std.Thread.sleep(interval);
            elapsed += interval;
        }
        // Timeout expired — mark connection as closing to unblock reads
        if (req.connection) |conn| {
            conn.closing = true;
        }
    }
};
