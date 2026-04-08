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
        return self.doGetLimited(url, extra_headers, MAX_BLOB_BYTES);
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

    fn doGet(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !Response {
        return self.doGetLimited(url, extra_headers, MAX_METADATA_BYTES);
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

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        // Wrap in a limited reader to enforce MAX_RESPONSE_BYTES.
        // Limited.interface is a Reader that stops at the byte limit.
        var limited_buf: [0]u8 = undefined;
        var limited = body_reader.limited(std.Io.Limit.limited(max_bytes), &limited_buf);
        const bytes_read = limited.interface.streamRemaining(&body_writer.writer) catch
            return error.ReadFailed;

        // If we read exactly the limit, the response may be truncated — reject it.
        if (bytes_read >= max_bytes) return error.ResponseTooLarge;

        const body = try body_writer.toOwnedSlice();

        return .{
            .status = status,
            .body = body,
            .allocator = self.allocator,
        };
    }
};
