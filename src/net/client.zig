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
    /// The caller owns the returned `Response` and must call `deinit` on it.
    pub fn get(self: *HttpClient, url: []const u8) !Response {
        return self.doGet(url, &.{});
    }

    /// Perform a GET request with extra headers (e.g. Authorization).
    /// The caller owns the returned `Response` and must call `deinit` on it.
    pub fn getWithHeaders(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !Response {
        return self.doGet(url, extra_headers);
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

    // ---- internal helper ----

    fn doGet(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
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

        // Read response body into an allocating writer.
        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();

        const body_reader = response.reader(&.{});
        _ = body_reader.streamRemaining(&body_writer.writer) catch
            return error.ReadFailed;

        const body = try body_writer.toOwnedSlice();

        return .{
            .status = status,
            .body = body,
            .allocator = self.allocator,
        };
    }
};
