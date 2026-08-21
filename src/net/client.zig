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

/// Explicit error set for the streaming GET (`getToWriter`). Net is a leaf
/// (Rule U1), so it returns a typed set the caller `switch`es on rather than
/// leaking std.http's inferred errors. Transport-level failures
/// (connect / TLS / reading the head) collapse to `RequestFailed`; by the time
/// one escapes, the retry loop has already exhausted its attempts.
pub const GetError = error{
    OfflineRequired,
    RequestFailed,
    /// The url does not parse. A property of the string, so no walk retries it.
    InvalidUrl,
    TlsDowngradeRefused,
    /// A manifest handed us a cleartext origin for a payload nothing else
    /// vouches for.
    InsecureUrlScheme,
    TooManyHttpRedirects,
    HttpRedirectInvalid,
    ResponseTooLarge,
    ReadFailed,
    WatchdogSpawnFailed,
    Canceled,
    OutOfMemory,
};

/// What the shared redirect decision can produce. Closed (Rule U1) so the retry
/// policy can be derived from it: every member is settled by the response or by
/// memory, never by the transport - the invariant `isRetriableWalkError` leans
/// on.
pub const RedirectError = error{
    HttpRedirectLocationMissing,
    HttpRedirectLocationInvalid,
    HttpRedirectLocationOversize,
    TooManyHttpRedirects,
    TlsDowngradeRefused,
    OutOfMemory,
};

/// Explicit error set for the classification walk. The cask installer switches
/// on it to tell a dead network from a cleartext artifact from a Ctrl-C - an
/// open set let one be reported as another.
pub const HeadResolveError = RedirectError || error{
    OfflineRequired,
    RequestFailed,
    InvalidUrl,
    InsecureUrlScheme,
    Canceled,
};

/// What still vouches for a payload once the transport does not.
///
/// Refusing every cleartext origin would cost the packages that are already
/// safe without buying anything: a digest published over https pins the bytes,
/// so a cleartext hop cannot substitute them undetected. The exemption is
/// deliberately narrow — only a caller that verifies a digest it did not learn
/// from the same connection may claim it.
pub const Integrity = enum {
    /// The caller checks the body against a digest obtained elsewhere.
    digest_pinned,
    /// Nothing behind the transport. Cleartext is refused.
    transport_only,
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

/// Statuses that never carry a body (RFC 9110 6.4.1). The release path
/// decides by request method alone, so a bodiless response that also omits
/// framing headers reads as "body ends when the peer closes" and blocks on
/// a keep-alive socket until the idle timeout.
pub fn statusHasNoBody(status: u16) bool {
    return (status >= 100 and status < 200) or status == 204 or status == 304;
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

    /// Upper bound on a streamed blob body before the cap trips
    /// `error.ResponseTooLarge`. Defaults to the production bound; tests lower
    /// it to exercise the cap without a multi-GiB fixture.
    blob_cap: usize = max_blob_bytes,

    /// Backoff before each retried attempt; its length is the retry budget.
    /// Defaults to the production schedule; tests shrink it so a retry can be
    /// observed without paying its wall-clock.
    retry_backoff_ms: []const u64 = &default_retry_backoff_ms,

    /// Reused across requests; each HttpClient is borrowed single-threaded
    /// from a pool, so no concurrent access.
    zstd_window: ?[]u8 = null,
    flate_window: ?[]u8 = null,

    const default_timeout_ns: u64 = 30 * std.time.ns_per_s;
    /// Blob downloads (bottles, cask DMGs) get a much longer timeout.
    const blob_timeout_ns: u64 = 600 * std.time.ns_per_s; // 10 minutes

    /// Process-wide cancel predicate seeded into every new client's `cancel`
    /// field. `main` injects the SIGINT flag once so all HTTP-using commands
    /// abort an in-flight fetch on Ctrl-C without each site re-wiring it; net/
    /// stays agnostic to which signal mechanism the caller chose.
    var default_cancel: ?*const fn () bool = null;

    pub fn setDefaultCancel(f: ?*const fn () bool) void {
        default_cancel = f;
    }

    pub fn defaultCancel() ?*const fn () bool {
        return default_cancel;
    }

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
            .cancel = default_cancel,
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

    /// Host component of an http(s) URL — no scheme, userinfo, port, or
    /// path. Null for non-http(s) inputs (never auth-eligible). Strips
    /// userinfo so `github.com@evil.tld` resolves to its real host
    /// `evil.tld`, closing the substring-match token leak.
    fn urlHost(url: []const u8) ?[]const u8 {
        const after_scheme = if (std.mem.startsWith(u8, url, "https://"))
            url["https://".len..]
        else if (std.mem.startsWith(u8, url, "http://"))
            url["http://".len..]
        else
            return null;

        var authority = after_scheme;
        if (std.mem.indexOfAny(u8, authority, "/?#")) |i| authority = authority[0..i];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority = authority[i + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |i| authority = authority[0..i];
        // A trailing dot is the FQDN root form of the same host (`github.com.`).
        if (authority.len > 0 and authority[authority.len - 1] == '.')
            authority = authority[0 .. authority.len - 1];
        return authority;
    }

    /// True when `url`'s host component is one of the GitHub/Homebrew hosts
    /// the metadata token is meant for. Matches the *host*, not a substring,
    /// so a look-alike like `https://github.com.evil.tld/` or a path like
    /// `https://evil.tld/github.com` never receives the token. Hosts are
    /// compared case-insensitively (DNS is case-insensitive), so a legit
    /// host never loses the token to capitalisation.
    /// Public so the host gate can be pinned without a live request — the
    /// credential-injection branch used to be covered by actually calling
    /// `formulae.brew.sh`, which sent whatever token the developer had
    /// exported to a third party.
    pub fn githubTokenApplies(url: []const u8) bool {
        const host = urlHost(url) orelse return false;
        if (std.ascii.eqlIgnoreCase(host, "github.com")) return true;
        if (std.ascii.endsWithIgnoreCase(host, ".github.com")) return true;
        if (std.ascii.eqlIgnoreCase(host, "formulae.brew.sh")) return true;
        if (std.ascii.eqlIgnoreCase(host, "ghcr.io")) return true;
        return false;
    }

    /// Token for the GitHub/Homebrew API `Authorization` header. Prefers
    /// `MALT_GITHUB_TOKEN` (malt's primary GitHub token, shared with tap
    /// lookups) and falls back to `HOMEBREW_GITHUB_API_TOKEN` for Homebrew
    /// compatibility. An empty value is treated as unset for each — mirroring
    /// `forge.authHeader` — so a leftover `MALT_GITHUB_TOKEN=` never shadows a
    /// real Homebrew token. Returns the bare token; the caller adds the scheme.
    pub fn githubApiToken(environ: std.process.Environ) ?[]const u8 {
        return nonEmptyEnv(environ, "MALT_GITHUB_TOKEN") orelse
            nonEmptyEnv(environ, "HOMEBREW_GITHUB_API_TOKEN");
    }

    fn nonEmptyEnv(environ: std.process.Environ, key: []const u8) ?[]const u8 {
        const raw = std.process.Environ.getPosix(environ, key) orelse return null;
        const v = std.mem.sliceTo(raw, 0);
        return if (v.len == 0) null else v;
    }

    /// http(s) scheme of a malt URL, or null for non-http(s). Used to gate
    /// whether a credential may follow a redirect — the scheme must match.
    fn urlScheme(url: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, url, "https://")) return "https";
        if (std.mem.startsWith(u8, url, "http://")) return "http";
        return null;
    }

    /// Mirrors std `HostName.sameParentDomain`: true iff `child` is `parent`
    /// or a dot-boundary subdomain of it (case-insensitive). A shared suffix
    /// without a dot boundary (`evilgithub.com` vs `github.com`) is not a match.
    fn hostIsSameOrSubdomain(parent: []const u8, child: []const u8) bool {
        if (!std.ascii.endsWithIgnoreCase(child, parent)) return false;
        if (child.len == parent.len) return true;
        if (parent.len > child.len) return false;
        return child[child.len - parent.len - 1] == '.';
    }

    /// Whether caller credentials/validators may survive a redirect `from`→`to`.
    /// Faithful to stdlib's `keep_privileged_headers`: same scheme AND the new
    /// host is the old host or a subdomain of it. Anything else drops the
    /// headers so a GitHub PAT / GHCR bearer never reaches an off-domain CDN or
    /// object store.
    /// HTTP status codes malt follows as a redirect. Deliberately an explicit
    /// set, not a `301..308` range: 304 (Not Modified) and 306 (unused) sit in
    /// that range but are NOT redirects — treating 304 as one breaks every
    /// conditional GET.
    fn isFollowableRedirect(status: u16) bool {
        return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
    }

    fn credsSurviveRedirect(from: []const u8, to: []const u8) bool {
        const fs = urlScheme(from) orelse return false;
        const ts = urlScheme(to) orelse return false;
        if (!std.ascii.eqlIgnoreCase(fs, ts)) return false;
        const fh = urlHost(from) orelse return false;
        const th = urlHost(to) orelse return false;
        return hostIsSameOrSubdomain(fh, th);
    }

    /// True for the loopback names a local fixture server binds. Cleartext to
    /// one of these never leaves the machine, so the https requirement below
    /// does not apply — and the test suites that stand up a throwaway HTTP
    /// server keep working without an escape hatch a real deployment could
    /// trip over.
    fn isLoopbackHost(host: []const u8) bool {
        return std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
            std.ascii.eqlIgnoreCase(host, "localhost") or
            std.ascii.eqlIgnoreCase(host, "::1") or
            std.ascii.eqlIgnoreCase(host, "[::1]");
    }

    /// Refuse a cleartext origin. The redirect loop already declines an
    /// https→http downgrade mid-chain, but the *initial* scheme came straight
    /// from a manifest: a tap that writes `http://` for a formula or cask URL
    /// got a plaintext fetch.
    ///
    /// `cli/tap.zig` already refuses `http://` when registering a tap; this
    /// applies the same rule to the URLs those taps hand back.
    pub fn requireSecureOrigin(url: []const u8, integrity: Integrity) error{InsecureUrlScheme}!void {
        if (std.mem.startsWith(u8, url, "https://")) return;
        // Only cleartext http is ever a candidate for the exemptions below;
        // `file://`, `ftp://` and an unparseable url stay refused either way.
        if (!std.mem.startsWith(u8, url, "http://")) return error.InsecureUrlScheme;
        if (integrity == .digest_pinned) return;
        const host = urlHost(url) orelse return error.InsecureUrlScheme;
        if (isLoopbackHost(host)) return;
        return error.InsecureUrlScheme;
    }

    /// GET request; auto-injects the GitHub API token (`MALT_GITHUB_TOKEN`,
    /// then `HOMEBREW_GITHUB_API_TOKEN`) as Authorization for GitHub/Homebrew
    /// hosts. Caller owns the returned `Response`.
    pub fn get(self: *HttpClient, url: []const u8) !Response {
        if (self.offline) return error.OfflineRequired;
        // Every caller fetches metadata from a hardcoded https host; none has
        // a digest to fall back on, so this one stays unconditional.
        try requireSecureOrigin(url, .transport_only);
        if (try self.authHeaderValue(url)) |auth_value| {
            defer self.allocator.free(auth_value);
            const headers = [_]std.http.Header{
                .{ .name = "Authorization", .value = auth_value },
            };
            return self.doGet(url, &headers);
        }
        return self.doGet(url, &.{});
    }

    /// Owned `Authorization` value (`token <t>`) for a gate-eligible URL, or
    /// null when no token applies. Sized exactly to the token so a long
    /// fine-grained / GitHub-App / GHCR token is never dropped. Caller frees
    /// the returned slice. Host-component match, not substring: a look-alike
    /// host or a path containing "github.com" never receives the token.
    fn authHeaderValue(self: *HttpClient, url: []const u8) !?[]u8 {
        const token = githubApiToken(self.environ) orelse return null;
        if (!githubTokenApplies(url)) return null;
        return try std.fmt.allocPrint(self.allocator, "token {s}", .{token});
    }

    /// GET with extra headers under `max_blob_bytes`. Caller owns `Response`.
    ///
    /// This is where a tap-supplied URL is actually downloaded, so `integrity`
    /// has no default: every call site has to say what backs the bytes it is
    /// about to trust.
    pub fn getWithHeaders(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        progress: ?ProgressCallback,
        integrity: Integrity,
    ) !Response {
        if (self.offline) return error.OfflineRequired;
        try requireSecureOrigin(url, integrity);
        return self.doGetWithRetry(url, extra_headers, max_blob_bytes, progress);
    }

    /// Streaming sibling of `getWithHeaders`: drains a 200 body straight into
    /// `sink` and returns only the status — no full-size body buffer. Non-200
    /// bodies go to a bounded throwaway so `sink` stays pristine until the
    /// response is definitively good, and a mid-200-stream failure is returned
    /// (never retried) so the single-use `sink` is written at most once. Net is
    /// a leaf, so the error set is explicit (Rule U1).
    pub fn getToWriter(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        sink: *std.Io.Writer,
        progress: ?ProgressCallback,
    ) GetError!u16 {
        if (self.offline) return error.OfflineRequired;
        // Only ghcr blob fetches land here, and those are https with the
        // digest in the URL.
        try requireSecureOrigin(url, .transport_only);
        return self.doGetToWriterWithRetry(url, extra_headers, sink, progress);
    }

    /// Perform a HEAD request and return only the HTTP status code.
    pub fn head(self: *HttpClient, url: []const u8) !u16 {
        if (self.offline) return error.OfflineRequired;
        // A HEAD returns no body to verify, so there is never a digest to
        // weigh against the transport.
        try requireSecureOrigin(url, .transport_only);
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
    ///
    /// Retried on the download's policy: this walk only classifies what the
    /// download then fetches, so a blip the fetch would have survived must not
    /// be fatal here. Each attempt re-walks from `url`; nothing pins a later
    /// attempt to the chain an earlier one saw.
    pub fn headResolved(self: *HttpClient, url: []const u8) HeadResolveError!HeadResolved {
        if (self.offline) return error.OfflineRequired;
        // The final url and Content-Disposition this returns pick a cask's
        // artifact type, and the pkg type reaches `sudo installer -target /`.
        // No digest covers a response header, so cleartext is refused outright.
        try requireSecureOrigin(url, .transport_only);

        var attempt: usize = 0;
        while (true) {
            if (self.headResolvedOnce(url)) |resolved| {
                return resolved;
            } else |err| {
                if (isRetriableWalkError(err) and attempt < self.retry_backoff_ms.len) {
                    try self.retrySleep(attempt);
                    attempt += 1;
                    continue;
                }
                return err;
            }
        }
    }

    fn headResolvedOnce(self: *HttpClient, url: []const u8) HeadResolveError!HeadResolved {
        // Build the result eagerly so a single errdefer covers every dupe
        // inside the redirect loop; on success the caller takes ownership.
        var resolved: HeadResolved = .{
            .final_url = try self.allocator.dupe(u8, url),
            .content_disposition = null,
            .allocator = self.allocator,
        };
        errdefer resolved.deinit();

        // Every exit below returns an error rather than what the walk reached
        // so far: a partial walk is indistinguishable from a resolved url, and
        // the caller picks a cask's artifact type from it.
        var hops: usize = 0;
        while (true) : (hops += 1) {
            const uri = std.Uri.parse(resolved.final_url) catch return error.InvalidUrl;

            var req = self.client.request(.HEAD, uri, .{
                .extra_headers = &.{},
            }) catch return error.RequestFailed;
            defer req.deinit();

            req.sendBodiless() catch return error.RequestFailed;

            var redirect_buf: [32 * 1024]u8 = undefined;
            const response = req.receiveHead(&redirect_buf) catch return error.RequestFailed;

            if (resolved.content_disposition == null) {
                if (response.head.content_disposition) |cd| {
                    resolved.content_disposition = try self.allocator.dupe(u8, cd);
                }
            }

            const status: u16 = @intFromEnum(response.head.status);
            const next = (try self.nextRedirectHop(uri, status, response.head.location, hops)) orelse break;
            defer self.allocator.free(next);
            try resolved.replaceFinalUrl(next);
        }

        return resolved;
    }

    /// Metadata cap (formula.json is ~25 MB; 50 MB gives headroom).
    const max_metadata_bytes: usize = 50 * 1024 * 1024;

    /// Bottle responses can be 500+ MB. We cap at 2 GB to prevent true OOM.
    const max_blob_bytes: usize = 2 * 1024 * 1024 * 1024;

    // ---- internal helper ----

    const default_retry_backoff_ms = [_]u64{ 1000, 2000, 4000 };

    /// Counts written bytes, enforces an upper bound mid-stream, and reports
    /// progress. On overflow `drain`/`sendFile` return `error.WriteFailed`
    /// and callers distinguish via `bytes_written` vs `limit_exceeded`.
    /// `bytes_written` is atomic so the idle watchdog (a separate thread)
    /// can sample it on each tick without a lock.
    const CountingWriter = struct {
        inner: *std.Io.Writer,
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
            // Refuse the over-cap chunk before the inner sink grows to hold it.
            // `drain` is the sole in-band writer, so a monotonic load suffices.
            const incoming = std.Io.Writer.countSplat(data, splat);
            if (self.bytes_written.load(.monotonic) + incoming > self.max_bytes) {
                self.limit_exceeded = true;
                return error.WriteFailed;
            }
            const n = self.inner.vtable.drain(self.inner, data, splat) catch
                return error.WriteFailed;
            const total = self.bytes_written.fetchAdd(n, .release) + n;
            self.report(total);
            return n;
        }

        fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
            const self: *CountingWriter = @fieldParentPtr("writer", w);
            const current = self.bytes_written.load(.monotonic);
            if (current >= self.max_bytes) {
                self.limit_exceeded = true;
                return error.WriteFailed;
            }
            // Clamp the source so a file cannot overshoot the cap either.
            const clamped = std.Io.Limit.min(limit, .limited64(self.max_bytes - current));
            const n = self.inner.vtable.sendFile(self.inner, file_reader, clamped) catch |e| return e;
            const total = self.bytes_written.fetchAdd(n, .release) + n;
            self.report(total);
            // Backstop: the clamp bounds the write, but keep the post-check.
            if (total > self.max_bytes) {
                self.limit_exceeded = true;
                return error.WriteFailed;
            }
            return n;
        }

        fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *CountingWriter = @fieldParentPtr("writer", w);
            return self.inner.vtable.flush(self.inner);
        }

        fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
            const self: *CountingWriter = @fieldParentPtr("writer", w);
            return self.inner.vtable.rebase(self.inner, preserve, capacity);
        }
    };

    fn doGet(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !Response {
        return self.doGetWithRetry(url, extra_headers, max_metadata_bytes, null);
    }

    /// Stream a response body into a caller-provided `sink` with the same
    /// decompress + idle/total watchdog + size cap the buffer path uses. The
    /// watchdog's spawn/join wraps the streaming call so a stalled sink is
    /// still killed. Both the generic GET and the conditional GET converge here
    /// so the single transport policy lives in one place — only the
    /// `total_timeout_ns` differs between callers (blob downloads scale it from
    /// `content_length`; metadata reads pin it to `self.timeout_ns`). The sink
    /// is single-use: on error it holds whatever bytes already arrived and net
    /// never rewinds it.
    fn streamResponseBody(
        self: *HttpClient,
        req: *std.http.Client.Request,
        response: *std.http.Client.Response,
        sink: *std.Io.Writer,
        max_bytes: usize,
        progress: ?ProgressCallback,
        total_timeout_ns: u64,
    ) !void {
        const content_length: ?u64 = response.head.content_length;

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
            .inner = sink,
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
    }

    /// Buffer wrapper over `streamResponseBody`: supplies its own `Allocating`
    /// writer so every existing metadata/JSON/blob GET keeps returning an owned
    /// slice, byte-for-byte unchanged by the sink split.
    fn readResponseBody(
        self: *HttpClient,
        req: *std.http.Client.Request,
        response: *std.http.Client.Response,
        max_bytes: usize,
        progress: ?ProgressCallback,
        total_timeout_ns: u64,
    ) !([]const u8) {
        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();
        try self.streamResponseBody(req, response, &body_writer.writer, max_bytes, progress, total_timeout_ns);
        return try body_writer.toOwnedSlice();
    }

    /// Failures no second walk can clear. Every redirect decision is one, plus
    /// the refusals and exhaustions the walk raises on its own behalf; a tag
    /// added to `RedirectError` joins this set without another edit.
    const TerminalWalkError = RedirectError || error{
        /// The streaming walk's collapsed form of the malformed-redirect tags.
        HttpRedirectInvalid,
        InvalidUrl,
        InsecureUrlScheme,
        ResponseTooLarge,
        OfflineRequired,
        /// The user's answer, not a fault to sleep off.
        Canceled,
    };

    /// Whether a second walk could plausibly reach a different answer. Only the
    /// terminal side is closed: the buffered GET's set is still inferred, so an
    /// unnamed tag arriving here defaults to retriable.
    fn isRetriableWalkError(err: anyerror) bool {
        inline for (@typeInfo(TerminalWalkError).error_set.?) |variant| {
            if (err == @field(TerminalWalkError, variant.name)) return false;
        }
        return true;
    }

    /// Cancellable backoff between retry attempts. Common to every
    /// retry loop so a Ctrl-C during the wait surfaces immediately
    /// instead of being swallowed by std.Io.sleep's silent return.
    fn retrySleep(self: *HttpClient, attempt: usize) error{Canceled}!void {
        std.Io.sleep(
            self.io,
            std.Io.Duration.fromNanoseconds(@intCast(self.retry_backoff_ms[attempt] * std.time.ns_per_ms)),
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
                    if (isTransientError(dl_err) and attempt < self.retry_backoff_ms.len) {
                        var r = resp;
                        r.deinit();
                        try self.retrySleep(attempt);
                        attempt += 1;
                        continue;
                    }
                }
                return resp;
            } else |err| {
                if (isRetriableWalkError(err) and attempt < self.retry_backoff_ms.len) {
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
        // Conditional GETs target tiny JSON, never blobs — the metadata cap
        // and timeout follow from `max_metadata_bytes` inside `followGet`.
        const out = try self.followGet(url, extra_headers, max_metadata_bytes, null, true);
        return .{
            .status = out.status,
            .not_modified = out.not_modified,
            .body = out.body,
            .etag = out.etag,
            .allocator = self.allocator,
        };
    }

    /// Redirect budget for every walk - matches stdlib's default so download
    /// depth is unchanged by taking over redirect handling. The HEAD walk that
    /// classifies a cask shares it, so it cannot resolve a chain the download
    /// would reject.
    pub const max_redirects: usize = 3;

    const GetOutcome = struct {
        status: u16,
        body: []const u8,
        etag: ?[]const u8,
        not_modified: bool,
    };

    /// Resolve a redirect `Location` (absolute or relative) against `base`
    /// into an owned absolute URL, dropping any userinfo. Uses std's own
    /// resolver so relative targets behave exactly as stdlib's auto-follow did.
    fn resolveRedirectUrl(self: *HttpClient, base: std.Uri, location: []const u8) RedirectError![]const u8 {
        var buf: [8 * 1024]u8 = undefined;
        if (location.len > buf.len) return error.HttpRedirectLocationOversize;
        @memcpy(buf[0..location.len], location);
        var aux: []u8 = buf[0..];
        const resolved = base.resolveInPlace(location.len, &aux) catch
            return error.HttpRedirectLocationInvalid;

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        resolved.writeToStream(&out.writer, .{
            .scheme = true,
            .authority = true,
            .port = true,
            .path = true,
            .query = true,
        }) catch return error.HttpRedirectLocationInvalid;
        return try out.toOwnedSlice();
    }

    /// Resolve one redirect hop, refusing it when the origin's TLS is dropped.
    /// Shared by all three redirect loops so the rule cannot drift between them.
    /// Resolving first matters: a relative `Location` carries no scheme and
    /// would otherwise read as a downgrade. Caller owns the returned slice.
    fn nextHopUrl(self: *HttpClient, base: std.Uri, location: []const u8) RedirectError![]const u8 {
        const next = try self.resolveRedirectUrl(base, location);
        errdefer self.allocator.free(next);
        const next_uri = std.Uri.parse(next) catch return error.HttpRedirectLocationInvalid;
        if (schemeIsHttps(base.scheme) and !schemeIsHttps(next_uri.scheme))
            return error.TlsDowngradeRefused;
        return next;
    }

    /// The redirect decision every walk shares, so the rules cannot drift
    /// between them. A missing `Location` and a spent budget both error here
    /// rather than reading as terminal - either one would otherwise hand back
    /// a url nothing ever requested as if it were resolved. Null means
    /// terminal; caller owns the url.
    fn nextRedirectHop(
        self: *HttpClient,
        base: std.Uri,
        status: u16,
        location: ?[]const u8,
        hops: usize,
    ) RedirectError!?[]const u8 {
        if (!isFollowableRedirect(status)) return null;
        const loc = location orelse return error.HttpRedirectLocationMissing;
        if (hops >= max_redirects) return error.TooManyHttpRedirects;
        return try self.nextHopUrl(base, loc);
    }

    /// Release a request whose response carries no body. stdlib's `deinit`
    /// decides by method alone, so on a bodiless status it drains until the
    /// peer closes — on a keep-alive 304 that is a full idle timeout.
    /// Declaring the body zero-length makes that drain a no-op.
    ///
    /// The connection is retired rather than pooled: if a broken peer did
    /// send bytes we never read, reuse would feed them to the next request
    /// as its response head.
    fn finishBodiless(req: *std.http.Client.Request) void {
        req.response_content_length = 0;
        req.response_transfer_encoding = .none;
        if (req.connection) |conn| conn.closing = true;
        req.deinit();
    }

    /// GET that follows redirects manually so credential/validator headers are
    /// stripped before leaving the origin's scope. In Zig 0.16 stdlib,
    /// `extra_headers` ride every redirect and `privileged_headers` are never
    /// sent at all — neither slot both authenticates the origin and drops on a
    /// cross-domain hop, so we own the loop. Credentials survive a hop only
    /// when scheme and parent domain are preserved; an https→http downgrade is
    /// refused outright (the secret would otherwise hit a cleartext socket and
    /// the plaintext body could be substituted).
    fn followGet(
        self: *HttpClient,
        url: []const u8,
        creds: []const std.http.Header,
        max_bytes: usize,
        progress: ?ProgressCallback,
        capture_etag: bool,
    ) !GetOutcome {
        var current: []const u8 = try self.allocator.dupe(u8, url);
        defer self.allocator.free(current);
        var live_creds = creds;
        var hops: usize = 0;

        while (true) : (hops += 1) {
            const uri = std.Uri.parse(current) catch return error.InvalidUrl;

            var req = try self.client.request(.GET, uri, .{
                .extra_headers = live_creds,
                .redirect_behavior = .unhandled,
            });
            errdefer req.deinit();

            try req.sendBodiless();
            var redirect_buf: [32 * 1024]u8 = undefined;
            var response = try req.receiveHead(&redirect_buf);
            const status: u16 = @intFromEnum(response.head.status);

            if (try self.nextRedirectHop(uri, status, response.head.location, hops)) |next| {
                errdefer self.allocator.free(next);
                if (!credsSurviveRedirect(current, next)) live_creds = &.{};
                // Hop committed: no fallible op past here, so the errdefers
                // stay dormant while we hand `req`/`current` off cleanly.
                req.deinit();
                self.allocator.free(current);
                current = next;
                continue;
            }

            // Terminal response. Etag is borrowed from the head buffer; dupe it
            // before the body read drops that buffer. `req`'s errdefer covers
            // every error path below; on a value return we deinit explicitly.
            var etag_owned: ?[]const u8 = null;
            errdefer if (etag_owned) |e| self.allocator.free(e);
            if (capture_etag) {
                if (extractEtagFromHead(response.head.bytes)) |e|
                    etag_owned = try self.allocator.dupe(u8, e);
            }

            // Empty owned slice keeps deinit's `free(body)` uniform.
            if (statusHasNoBody(status)) {
                const empty = try self.allocator.alloc(u8, 0);
                finishBodiless(&req);
                return .{ .status = status, .body = empty, .etag = etag_owned, .not_modified = status == 304 };
            }

            const total_timeout = if (max_bytes > max_metadata_bytes)
                @max(blob_timeout_ns, scaledTimeoutNs(response.head.content_length))
            else
                self.timeout_ns;
            const body = try self.readResponseBody(&req, &response, max_bytes, progress, total_timeout);
            req.deinit();
            return .{ .status = status, .body = body, .etag = etag_owned, .not_modified = false };
        }
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
                    if (isTransientError(dl_err) and attempt < self.retry_backoff_ms.len) {
                        resp.allocator.free(resp.body);
                        // Cancellation is single-shot per task in std.Io —
                        // swallowing it here means the caller's stop signal
                        // is consumed by the backoff and never reaches the
                        // next request, so propagate it as the result.
                        try self.retrySleep(attempt);
                        attempt += 1;
                        continue;
                    }
                }
                return resp;
            } else |err| {
                if (isRetriableWalkError(err) and attempt < self.retry_backoff_ms.len) {
                    try self.retrySleep(attempt);
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
        const out = try self.followGet(url, extra_headers, max_bytes, progress, false);
        return .{
            .status = out.status,
            .body = out.body,
            .allocator = self.allocator,
        };
    }

    /// Streaming counterpart of `doGetWithRetry`: threads `sink` through and
    /// returns status only. The pre-body retry (transient status, transport
    /// failure) still fires because the sink is untouched until a 200 body
    /// starts draining — `followGetToWriter` flips `sink_committed` at that
    /// point, and once it is set a mid-stream failure is surfaced, never
    /// retried, keeping the sink single-use.
    fn doGetToWriterWithRetry(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        sink: *std.Io.Writer,
        progress: ?ProgressCallback,
    ) GetError!u16 {
        var attempt: usize = 0;
        while (true) {
            var sink_committed = false;
            const result = self.followGetToWriter(url, extra_headers, sink, progress, &sink_committed);
            if (result) |status| {
                if (classifyStatus(status)) |dl_err| {
                    if (isTransientError(dl_err) and attempt < self.retry_backoff_ms.len) {
                        try self.retrySleep(attempt);
                        attempt += 1;
                        continue;
                    }
                }
                return status;
            } else |err| {
                // Past the 200 commit the sink holds partial bytes and cannot
                // be rewound, so the caller owns recovery: surface the error
                // instead of retrying into a dirty sink.
                if (sink_committed) return err;
                if (isRetriableWalkError(err) and attempt < self.retry_backoff_ms.len) {
                    try self.retrySleep(attempt);
                    attempt += 1;
                    continue;
                }
                return err;
            }
        }
    }

    /// Redirect-following streaming GET (mirrors `followGet`, minus the etag
    /// capture and the owned-slice return). A 200 body streams into `sink`
    /// after `sink_committed` is set; any non-200 body drains into a bounded
    /// discard so status classification and connection reuse behave as on the
    /// buffer path while `sink` stays pristine.
    fn followGetToWriter(
        self: *HttpClient,
        url: []const u8,
        creds: []const std.http.Header,
        sink: *std.Io.Writer,
        progress: ?ProgressCallback,
        sink_committed: *bool,
    ) GetError!u16 {
        var current: []const u8 = self.allocator.dupe(u8, url) catch return error.OutOfMemory;
        defer self.allocator.free(current);
        var live_creds = creds;
        var hops: usize = 0;

        while (true) : (hops += 1) {
            const uri = std.Uri.parse(current) catch return error.InvalidUrl;

            var req = self.client.request(.GET, uri, .{
                .extra_headers = live_creds,
                .redirect_behavior = .unhandled,
            }) catch return error.RequestFailed;
            errdefer req.deinit();

            req.sendBodiless() catch return error.RequestFailed;
            var redirect_buf: [32 * 1024]u8 = undefined;
            var response = req.receiveHead(&redirect_buf) catch return error.RequestFailed;
            const status: u16 = @intFromEnum(response.head.status);

            // Exhaustive on purpose: a new redirect outcome must be given a
            // name here rather than defaulting into "malformed".
            const hop = self.nextRedirectHop(uri, status, response.head.location, hops) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TlsDowngradeRefused => return error.TlsDowngradeRefused,
                error.TooManyHttpRedirects => return error.TooManyHttpRedirects,
                error.HttpRedirectLocationMissing,
                error.HttpRedirectLocationInvalid,
                error.HttpRedirectLocationOversize,
                => return error.HttpRedirectInvalid,
            };
            if (hop) |next| {
                errdefer self.allocator.free(next);
                if (!credsSurviveRedirect(current, next)) live_creds = &.{};
                req.deinit();
                self.allocator.free(current);
                current = next;
                continue;
            }

            const total_timeout = @max(blob_timeout_ns, scaledTimeoutNs(response.head.content_length));

            if (status == 200) {
                // Commit point: past here a transport failure must not retry.
                sink_committed.* = true;
                try self.streamResponseBody(&req, &response, sink, self.blob_cap, progress, total_timeout);
                req.deinit();
                return status;
            }

            // Nothing to drain when the status forbids a body, and trying
            // would block until the idle timeout.
            if (statusHasNoBody(status)) {
                finishBodiless(&req);
                return status;
            }

            // Non-200: drain the error body into a bounded discard so status
            // classification / pre-body retry behave as on the buffer path and
            // the pooled connection stays reusable — all while `sink` is left
            // untouched.
            // Zero-length buffer: `CountingWriter` sits on top and delegates
            // every write straight to `drain`, so the discard never buffers.
            var discard_buf: [0]u8 = undefined;
            var discarding: std.Io.Writer.Discarding = .init(&discard_buf);
            try self.streamResponseBody(&req, &response, &discarding.writer, max_metadata_bytes, null, self.timeout_ns);
            req.deinit();
            return status;
        }
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

test "statusHasNoBody covers exactly the bodiless statuses" {
    // 204 and 304 are the reachable ones; 1xx is in the rule regardless.
    try std.testing.expect(statusHasNoBody(204));
    try std.testing.expect(statusHasNoBody(304));

    // Both ends of the 1xx range, and the values just outside it.
    try std.testing.expect(statusHasNoBody(100));
    try std.testing.expect(statusHasNoBody(199));
    try std.testing.expect(!statusHasNoBody(99));
    try std.testing.expect(!statusHasNoBody(200));

    // Everything else carries a body, and draining it is what keeps a
    // pooled connection reusable. 205 and 304 are one apart; so are 204
    // and 205.
    try std.testing.expect(!statusHasNoBody(203));
    try std.testing.expect(!statusHasNoBody(205));
    try std.testing.expect(!statusHasNoBody(303));
    try std.testing.expect(!statusHasNoBody(305));
    try std.testing.expect(!statusHasNoBody(404));
    try std.testing.expect(!statusHasNoBody(500));
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

test "HttpClient.init: inherits the process-wide default cancel predicate" {
    const Probe = struct {
        fn cancel() bool {
            return true;
        }
    };
    const prior = HttpClient.defaultCancel();
    defer HttpClient.setDefaultCancel(prior);

    // Once `main` injects a predicate, every client is interruptible without
    // each call site re-wiring `http.cancel`.
    HttpClient.setDefaultCancel(&Probe.cancel);
    var http = HttpClient.init(std.Options.debug_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();
    try std.testing.expectEqual(@as(?*const fn () bool, &Probe.cancel), http.cancel);

    // Clearing the default returns clients to non-cancelling.
    HttpClient.setDefaultCancel(null);
    var plain = HttpClient.init(std.Options.debug_io, std.process.Environ.empty, std.testing.allocator);
    defer plain.deinit();
    try std.testing.expectEqual(@as(?*const fn () bool, null), plain.cancel);
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

// ── githubTokenApplies: host-component match ───────────────────────
// Security-sensitive: a substring match leaked the metadata token to
// any URL *containing* "github.com" — a look-alike host or even a path
// segment. The token must ride only on the real GitHub/Homebrew hosts.

test "githubTokenApplies: matches github.com and its api subdomain" {
    try std.testing.expect(HttpClient.githubTokenApplies("https://github.com/Homebrew/homebrew-core"));
    try std.testing.expect(HttpClient.githubTokenApplies("https://api.github.com/repos/x/y/commits/HEAD"));
}

test "githubTokenApplies: matches formulae.brew.sh and ghcr.io" {
    try std.testing.expect(HttpClient.githubTokenApplies("https://formulae.brew.sh/api/formula/glow.json"));
    try std.testing.expect(HttpClient.githubTokenApplies("https://ghcr.io/v2/homebrew/core/glow/manifests/1.0"));
}

test "githubTokenApplies: rejects a look-alike host suffix" {
    // The core leak: `github.com.evil.tld`'s host is not github.com.
    try std.testing.expect(!HttpClient.githubTokenApplies("https://github.com.evil.tld/Homebrew/x"));
    try std.testing.expect(!HttpClient.githubTokenApplies("https://api.github.com.evil.tld/x"));
}

test "githubTokenApplies: rejects the host in userinfo or path" {
    // userinfo before '@' is not the host; a path segment is not the host.
    try std.testing.expect(!HttpClient.githubTokenApplies("https://github.com@evil.tld/x"));
    try std.testing.expect(!HttpClient.githubTokenApplies("https://evil.tld/github.com"));
}

test "githubTokenApplies: rejects non-forge and raw hosts" {
    // raw.githubusercontent.com is a different host and was never matched.
    try std.testing.expect(!HttpClient.githubTokenApplies("https://raw.githubusercontent.com/x/y/HEAD/F.rb"));
    try std.testing.expect(!HttpClient.githubTokenApplies("https://gitlab.com/o/r"));
    try std.testing.expect(!HttpClient.githubTokenApplies("https://example.com/x"));
}

test "githubTokenApplies: tolerates a port and matches the host" {
    try std.testing.expect(HttpClient.githubTokenApplies("https://github.com:443/x"));
    try std.testing.expect(!HttpClient.githubTokenApplies("https://github.com.evil.tld:8443/x"));
}

test "githubTokenApplies: matches a host-only URL with no path" {
    try std.testing.expect(HttpClient.githubTokenApplies("https://github.com"));
}

test "githubTokenApplies: rejects non-http(s) schemes and empty input" {
    // urlHost only resolves http(s); anything else is never auth-eligible.
    try std.testing.expect(!HttpClient.githubTokenApplies("git://github.com/x"));
    try std.testing.expect(!HttpClient.githubTokenApplies("ssh://git@github.com/x"));
    try std.testing.expect(!HttpClient.githubTokenApplies(""));
}

test "githubTokenApplies: host comparison is case-insensitive (no token lost to caps)" {
    try std.testing.expect(HttpClient.githubTokenApplies("https://GitHub.com/Homebrew/x"));
    try std.testing.expect(HttpClient.githubTokenApplies("https://API.GITHUB.COM/repos/x"));
    // ...but a capitalised look-alike is still rejected.
    try std.testing.expect(!HttpClient.githubTokenApplies("https://GitHub.com.evil.tld/x"));
}

test "githubTokenApplies: tolerates the FQDN trailing-dot root form" {
    try std.testing.expect(HttpClient.githubTokenApplies("https://github.com./x"));
    try std.testing.expect(HttpClient.githubTokenApplies("https://api.github.com./x"));
    try std.testing.expect(!HttpClient.githubTokenApplies("https://github.com.evil.tld./x"));
}

// ── githubApiToken: env-var precedence ─────────────────────────────
// The self-update GET (api.github.com/releases/latest) must honour the
// project's primary token, MALT_GITHUB_TOKEN, not only the Homebrew
// compatibility var — otherwise a user with one token still hits the
// anonymous rate cap on `version update`.

fn environFrom(entries: [:null]const ?[*:0]const u8) std.process.Environ {
    return .{ .block = .{ .slice = entries } };
}

test "requireSecureOrigin: refuses a cleartext manifest origin" {
    // A tap controls the `url` field of a formula or cask. With no digest to
    // fall back on, the transport is all that stands between the manifest and
    // an installed artifact.
    const bad = [_][]const u8{
        "http://example.com/pkg.tar.gz",
        "http://github.com/x/y",
        "http://192.168.1.10/pkg.dmg",
        "http://evil.tld/127.0.0.1/pkg.zip", // loopback in the *path*, not the host
        "http://127.0.0.1.evil.tld/pkg.zip", // and not as a prefix of the host
        "ftp://example.com/pkg.tar.gz",
        "file:///etc/passwd",
        "not-a-url",
        "",
    };
    for (bad) |u| try std.testing.expectError(
        error.InsecureUrlScheme,
        HttpClient.requireSecureOrigin(u, .transport_only),
    );
}

test "requireSecureOrigin: allows https anywhere and cleartext only to loopback" {
    // The loopback carve-out is what keeps the fixture-server tests honest
    // without giving a real deployment a way to opt out.
    const ok = [_][]const u8{
        "https://formulae.brew.sh/api/formula/jq.json",
        "https://ghcr.io/v2/x/blobs/sha256:ab",
        "http://127.0.0.1:8080/blob",
        "http://localhost:1234/start",
        "http://LOCALHOST:1/x",
    };
    for (ok) |u| try HttpClient.requireSecureOrigin(u, .transport_only);
}

test "requireSecureOrigin: a digest-pinned payload may come over cleartext http" {
    // Upstream ships ~29 formulae and casks on `http://` whose bytes are
    // pinned by a sha256 from the https manifest. Refusing those buys no
    // integrity — substitution is already detected — and only breaks installs
    // that Homebrew itself performs.
    const ok = [_][]const u8{
        "http://ck.kolivas.org/apps/lrzip/lrzip-0.641.tar.xz",
        "http://www.apptivateapp.com/resources/Apptivate-2.2.1.app.zip",
    };
    for (ok) |u| try HttpClient.requireSecureOrigin(u, .digest_pinned);
}

test "every url entry point refuses a cleartext origin before dialling out" {
    // A guard added to some of the entry points and not the rest is the whole
    // failure mode: `headResolved` takes a cask url too, and the type it hands
    // back decides whether the artifact is fed to `sudo installer`.
    const a = std.testing.allocator;
    var http = HttpClient.init(std.Options.debug_io, .empty, a);
    defer http.deinit();

    const url = "http://example.com/pkg";
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();

    try std.testing.expectError(error.InsecureUrlScheme, http.get(url));
    try std.testing.expectError(error.InsecureUrlScheme, http.getWithHeaders(url, &.{}, null, .transport_only));
    try std.testing.expectError(error.InsecureUrlScheme, http.getToWriter(url, &.{}, &sink.writer, null));
    try std.testing.expectError(error.InsecureUrlScheme, http.head(url));
    try std.testing.expectError(error.InsecureUrlScheme, http.headResolved(url));
}

test "requireSecureOrigin: a digest never buys a non-http scheme" {
    // The exemption is for cleartext transport, not for reading the local
    // filesystem or dialling ftp; a manifest must not reach those at all.
    const bad = [_][]const u8{
        "file:///etc/passwd",
        "ftp://example.com/pkg.tar.gz",
        "not-a-url",
        "",
    };
    for (bad) |u| try std.testing.expectError(
        error.InsecureUrlScheme,
        HttpClient.requireSecureOrigin(u, .digest_pinned),
    );
}

test "githubTokenApplies: only the four credential-bearing hosts match" {
    const yes = [_][]const u8{
        "https://github.com/indaco/malt",
        "https://api.github.com/repos/x/y",
        "https://formulae.brew.sh/api/formula/jq.json",
        "https://ghcr.io/v2/homebrew/core/jq/blobs/sha256:ab",
        "https://GitHub.com/x", // the host comparison is case-insensitive
        "https://github.com./x", // FQDN root form of the same host
        "https://user@github.com/x", // userinfo is stripped before matching
        "https://github.com:443/x", // as is the port
    };
    for (yes) |u| try std.testing.expect(HttpClient.githubTokenApplies(u));
}

test "githubTokenApplies: a look-alike host or a path lookalike never gets the token" {
    // The gate is a host-component match precisely so these cannot collect a
    // credential; pin that rather than trusting the comment.
    const no = [_][]const u8{
        "https://github.com.evil.tld/x",
        "https://evil.tld/github.com",
        "https://notgithub.com/x",
        "https://formulae.brew.sh.evil.tld/x",
        "https://ghcr.io.evil.tld/x",
        "https://evil.tld/?u=https://ghcr.io/",
        "https://xghcr.io/x",
        "not-a-url",
        "",
        // The scheme is matched case-sensitively, so this yields no host at
        // all. That is fail-closed (no credential leaves), so it is pinned
        // here as the current, safe behaviour rather than treated as a match.
        "HTTPS://github.com/x",
    };
    for (no) |u| try std.testing.expect(!HttpClient.githubTokenApplies(u));
}

test "githubApiToken: MALT_GITHUB_TOKEN is preferred over HOMEBREW_GITHUB_API_TOKEN" {
    const entries = [_:null]?[*:0]const u8{
        "MALT_GITHUB_TOKEN=malt-tok".ptr,
        "HOMEBREW_GITHUB_API_TOKEN=brew-tok".ptr,
    };
    try std.testing.expectEqualStrings("malt-tok", HttpClient.githubApiToken(environFrom(&entries)).?);
}

test "githubApiToken: empty MALT_GITHUB_TOKEN falls through to HOMEBREW_GITHUB_API_TOKEN" {
    // A leftover `MALT_GITHUB_TOKEN=` in a shell rc must not shadow a real
    // HOMEBREW token (mirrors forge.authHeader's empty-as-unset guard).
    const entries = [_:null]?[*:0]const u8{
        "MALT_GITHUB_TOKEN=".ptr,
        "HOMEBREW_GITHUB_API_TOKEN=brew-tok".ptr,
    };
    try std.testing.expectEqualStrings("brew-tok", HttpClient.githubApiToken(environFrom(&entries)).?);
}

test "githubApiToken: MALT_GITHUB_TOKEN alone is honoured" {
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=malt-tok".ptr};
    try std.testing.expectEqualStrings("malt-tok", HttpClient.githubApiToken(environFrom(&entries)).?);
}

test "githubApiToken: HOMEBREW_GITHUB_API_TOKEN alone still works (compat fallback)" {
    const entries = [_:null]?[*:0]const u8{"HOMEBREW_GITHUB_API_TOKEN=brew-tok".ptr};
    try std.testing.expectEqualStrings("brew-tok", HttpClient.githubApiToken(environFrom(&entries)).?);
}

test "githubApiToken: null when neither var is set or both are empty" {
    try std.testing.expect(HttpClient.githubApiToken(std.process.Environ.empty) == null);
    const empties = [_:null]?[*:0]const u8{
        "MALT_GITHUB_TOKEN=".ptr,
        "HOMEBREW_GITHUB_API_TOKEN=".ptr,
    };
    try std.testing.expect(HttpClient.githubApiToken(environFrom(&empties)) == null);
}

test "githubApiToken: empty MALT with HOMEBREW absent is null (no phantom token)" {
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=".ptr};
    try std.testing.expect(HttpClient.githubApiToken(environFrom(&entries)) == null);
}

test "githubApiToken: a non-empty value is taken verbatim, not trimmed (matches forge.authHeader)" {
    // forge.authHeader guards on len==0 only — no whitespace trim — so a
    // whitespace-only MALT_GITHUB_TOKEN is a set value and must not fall
    // through to HOMEBREW. Locks that deliberate divergence from mirror.zig.
    const entries = [_:null]?[*:0]const u8{
        "MALT_GITHUB_TOKEN=  ".ptr,
        "HOMEBREW_GITHUB_API_TOKEN=brew-tok".ptr,
    };
    try std.testing.expectEqualStrings("  ", HttpClient.githubApiToken(environFrom(&entries)).?);
}

// ── authHeaderValue: exact-sized header, no length-triggered drop ───
// The bug: `get` formatted the header into a fixed 256-byte stack buffer
// and, on overflow, silently issued an *unauthenticated* request — a long
// fine-grained / GitHub-App / GHCR token was dropped with no error. The
// decision lives in this helper so the produced value is observable
// without a live socket (stdlib exposes no resolver seam to point a
// gate-eligible host at loopback).

test "authHeaderValue: a >256-byte token still yields a full, untruncated header" {
    // "token " + 400 chars overflows the old 256-byte buffer — the exact
    // input that used to drop the token to an anonymous request.
    const token = "a" ** 400;
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=" ++ token};
    var http = HttpClient.init(std.Options.debug_io, environFrom(&entries), std.testing.allocator);
    defer http.deinit();

    const value = try http.authHeaderValue("https://github.com/Homebrew/x") orelse
        return error.TestUnexpectedNull;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("token " ++ token, value);
}

test "authHeaderValue: a short token yields the correct full value (happy path)" {
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=ghp_shorttoken"};
    var http = HttpClient.init(std.Options.debug_io, environFrom(&entries), std.testing.allocator);
    defer http.deinit();

    const value = try http.authHeaderValue("https://github.com/x") orelse
        return error.TestUnexpectedNull;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("token ghp_shorttoken", value);
}

test "authHeaderValue: a non-gate host returns null (gate unchanged)" {
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=ghp_shorttoken"};
    var http = HttpClient.init(std.Options.debug_io, environFrom(&entries), std.testing.allocator);
    defer http.deinit();
    try std.testing.expect(try http.authHeaderValue("https://example.com/x") == null);
}

test "authHeaderValue: no token returns null even for a gate host" {
    var http = HttpClient.init(std.Options.debug_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();
    try std.testing.expect(try http.authHeaderValue("https://github.com/x") == null);
}

test "authHeaderValue: surfaces OutOfMemory instead of silently dropping the token" {
    // The pre-fix bug was a *silent* fall-through to an anonymous request on
    // format failure. Allocation failure must fail loud — OOM propagates, it
    // must never revert to null/anonymous.
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=ghp_shorttoken"};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.Options.debug_io };
    var http = HttpClient.initWith(&inner, std.Options.debug_io, environFrom(&entries), failing.allocator());
    defer http.deinit();
    try std.testing.expectError(error.OutOfMemory, http.authHeaderValue("https://github.com/x"));
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

test "headResolved surfaces sleep cancellation instead of finishing the backoff" {
    // The classification walk gained a retry, so it also gained a window where
    // Ctrl-C lands in the backoff. The cask installer reports that case as an
    // interruption rather than a dead network, which only holds if the tag
    // reaches it intact.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const cancel_io = CancelSleepProbe.wrap(threaded.io(), 1);

    var http = HttpClient.init(cancel_io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    // Nothing listens on port 1, so the walk fails on connect and reaches the
    // first backoff without waiting on the network.
    const result = http.headResolved("http://127.0.0.1:1/extensionless");
    try std.testing.expectError(error.Canceled, result);
    try std.testing.expectEqual(@as(usize, 1), CancelSleepProbe.sleep_calls);
}

test "isRetriableWalkError: every redirect decision is terminal" {
    // The predicate derives its terminal side from these sets. Asserting the
    // derivation - rather than a hand-written list - is what stops a tag added
    // to RedirectError from becoming retriable by omission.
    inline for (@typeInfo(RedirectError).error_set.?) |variant| {
        try std.testing.expect(!HttpClient.isRetriableWalkError(@field(RedirectError, variant.name)));
    }
}

test "isRetriableWalkError: transport faults retry, refusals and exhaustions do not" {
    // The HEAD walk collapses every transport fault into RequestFailed, while
    // the buffered GET leaks the stdlib tag - both must stay retriable.
    try std.testing.expect(HttpClient.isRetriableWalkError(error.RequestFailed));
    try std.testing.expect(HttpClient.isRetriableWalkError(error.ReadFailed));
    try std.testing.expect(HttpClient.isRetriableWalkError(error.ConnectionResetByPeer));
    try std.testing.expect(HttpClient.isRetriableWalkError(error.WatchdogSpawnFailed));

    // Re-walking any of these reaches the same answer, just later.
    try std.testing.expect(!HttpClient.isRetriableWalkError(error.InvalidUrl));
    try std.testing.expect(!HttpClient.isRetriableWalkError(error.HttpRedirectInvalid));
    try std.testing.expect(!HttpClient.isRetriableWalkError(error.InsecureUrlScheme));
    try std.testing.expect(!HttpClient.isRetriableWalkError(error.ResponseTooLarge));
    try std.testing.expect(!HttpClient.isRetriableWalkError(error.OfflineRequired));
    try std.testing.expect(!HttpClient.isRetriableWalkError(error.Canceled));
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

// --- credential strip across redirects (keep_privileged_headers parity) ---

test "credsSurviveRedirect: kept on the same host and scheme" {
    try std.testing.expect(HttpClient.credsSurviveRedirect("https://github.com/a", "https://github.com/b"));
}

test "credsSurviveRedirect: kept descending to a subdomain of the origin" {
    try std.testing.expect(HttpClient.credsSurviveRedirect("https://github.com/a", "https://api.github.com/b"));
}

test "credsSurviveRedirect: dropped on a cross parent-domain hop" {
    try std.testing.expect(!HttpClient.credsSurviveRedirect("https://github.com/x", "https://objects.githubusercontent.com/y"));
}

test "credsSurviveRedirect: dropped when ascending to a broader host" {
    try std.testing.expect(!HttpClient.credsSurviveRedirect("https://api.github.com/x", "https://github.com/y"));
}

test "credsSurviveRedirect: dropped on https to http downgrade" {
    try std.testing.expect(!HttpClient.credsSurviveRedirect("https://github.com/x", "http://github.com/y"));
}

test "credsSurviveRedirect: dropped for a look-alike suffix without a dot boundary" {
    try std.testing.expect(!HttpClient.credsSurviveRedirect("https://github.com/x", "https://evilgithub.com/y"));
}

// --- redirect hop resolution (shared by the HEAD and both GET loops) ---

fn expectHop(base_url: []const u8, location: []const u8, want: []const u8) !void {
    const a = std.testing.allocator;
    var http = HttpClient.init(std.Options.debug_io, .empty, a);
    defer http.deinit();
    const next = try http.nextHopUrl(try std.Uri.parse(base_url), location);
    defer a.free(next);
    try std.testing.expectEqualStrings(want, next);
}

fn expectHopError(base_url: []const u8, location: []const u8, want: anyerror) !void {
    const a = std.testing.allocator;
    var http = HttpClient.init(std.Options.debug_io, .empty, a);
    defer http.deinit();
    try std.testing.expectError(want, http.nextHopUrl(try std.Uri.parse(base_url), location));
}

test "nextHopUrl refuses an https to http downgrade" {
    // The headers harvested from the hop pick a cask's artifact type, and the
    // pkg type reaches `sudo installer -target /`.
    try expectHopError("https://example.com/a", "http://example.com/b", error.TlsDowngradeRefused);
}

test "nextHopUrl refuses a downgrade announced with an upper-case scheme" {
    try expectHopError("https://example.com/a", "HTTP://example.com/b", error.TlsDowngradeRefused);
}

test "nextHopUrl allows an https to https hop" {
    try expectHop("https://example.com/a", "https://cdn.example.com/b", "https://cdn.example.com/b");
}

test "nextHopUrl allows a cleartext origin to hop to cleartext" {
    // Loopback fixtures dial http and must keep working; the rule is "do not
    // lose TLS", not "require TLS" — the origin guard already decides that.
    try expectHop("http://127.0.0.1:8080/a", "http://127.0.0.1:9090/b", "http://127.0.0.1:9090/b");
}

test "nextHopUrl allows a cleartext origin to upgrade to https" {
    try expectHop("http://example.com/a", "https://example.com/b", "https://example.com/b");
}

test "nextHopUrl keeps a relative location on the base scheme" {
    // A relative Location carries no scheme, so it must be resolved before the
    // comparison or every relative hop would read as a downgrade.
    try expectHop("https://example.com/a/b", "/c", "https://example.com/c");
    try expectHop("http://127.0.0.1:8080/a/b", "/c", "http://127.0.0.1:8080/c");
}

test "nextHopUrl inherits the base scheme for a scheme-relative location" {
    try expectHop("https://example.com/a", "//cdn.example.com/b", "https://cdn.example.com/b");
}

test "nextHopUrl accepts a location landing exactly on the size cap" {
    // Pins which side of the cap is inclusive, so the reject test above cannot
    // drift into rejecting locations that were always legal.
    const a = std.testing.allocator;
    const at_cap = try a.alloc(u8, 8 * 1024);
    defer a.free(at_cap);
    at_cap[0] = '/';
    @memset(at_cap[1..], 'a');

    var want: std.Io.Writer.Allocating = .init(a);
    defer want.deinit();
    try want.writer.writeAll("https://example.com");
    try want.writer.writeAll(at_cap);

    try expectHop("https://example.com/a", at_cap, want.written());
}

test "nextHopUrl rejects an oversize location before resolving it" {
    const a = std.testing.allocator;
    const huge = try a.alloc(u8, 9 * 1024);
    defer a.free(huge);
    @memset(huge, 'x');
    try expectHopError("https://example.com/a", huge, error.HttpRedirectLocationOversize);
}

test "isFollowableRedirect: follows 301/302/303/307/308" {
    for ([_]u16{ 301, 302, 303, 307, 308 }) |s|
        try std.testing.expect(HttpClient.isFollowableRedirect(s));
}

test "isFollowableRedirect: never follows 304 Not Modified or 306" {
    // 304 sits inside 301..308 but must fall through to the conditional-GET
    // handler, not the redirect path.
    try std.testing.expect(!HttpClient.isFollowableRedirect(304));
    try std.testing.expect(!HttpClient.isFollowableRedirect(306));
}

test "isFollowableRedirect: ignores 2xx/300/305 and other statuses" {
    for ([_]u16{ 200, 204, 300, 305, 400, 404, 500 }) |s|
        try std.testing.expect(!HttpClient.isFollowableRedirect(s));
}

// Drives drain over a real Allocating writer so the committed length is
// observable — the cap must bind before the inner write, not after.
fn drainOnce(cw: *HttpClient.CountingWriter, chunk: []const u8) std.Io.Writer.Error!usize {
    return cw.writer.vtable.drain(&cw.writer, &.{chunk}, 1);
}

test "CountingWriter.drain: refuses the over-cap chunk before allocating it" {
    var inner: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer inner.deinit();
    var cw = HttpClient.CountingWriter{
        .inner = &inner.writer,
        .bytes_written = std.atomic.Value(u64).init(0),
        .max_bytes = 10,
        .limit_exceeded = false,
        .progress = null,
        .content_length = null,
    };

    try std.testing.expectEqual(@as(usize, 8), try drainOnce(&cw, "abcdefgh"));
    // Second chunk pushes the total to 13 (> 10): must be refused whole.
    try std.testing.expectError(error.WriteFailed, drainOnce(&cw, "ijklm"));
    try std.testing.expect(cw.limit_exceeded);
    // Peak commit stays at or below the cap — the over-cap bytes never landed.
    try std.testing.expect(inner.writer.end <= cw.max_bytes);
    try std.testing.expectEqual(@as(usize, 8), inner.writer.end);
}

test "CountingWriter.drain: accepts a chunk landing exactly on max_bytes" {
    var inner: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer inner.deinit();
    var cw = HttpClient.CountingWriter{
        .inner = &inner.writer,
        .bytes_written = std.atomic.Value(u64).init(0),
        .max_bytes = 10,
        .limit_exceeded = false,
        .progress = null,
        .content_length = null,
    };

    try std.testing.expectEqual(@as(usize, 6), try drainOnce(&cw, "abcdef"));
    // total == max_bytes is inclusive (check is strictly `>`).
    try std.testing.expectEqual(@as(usize, 4), try drainOnce(&cw, "ghij"));
    try std.testing.expect(!cw.limit_exceeded);
    try std.testing.expectEqual(@as(usize, 10), inner.writer.end);
}

test "CountingWriter.drain: over-cap detected via splat count, not just data len" {
    var inner: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer inner.deinit();
    var cw = HttpClient.CountingWriter{
        .inner = &inner.writer,
        .bytes_written = std.atomic.Value(u64).init(0),
        .max_bytes = 4,
        .limit_exceeded = false,
        .progress = null,
        .content_length = null,
    };

    // countSplat("ab" x3) == 6 > 4: the repeated last vector must be counted
    // before delegating, otherwise the bound is read from data.len alone.
    try std.testing.expectError(error.WriteFailed, cw.writer.vtable.drain(&cw.writer, &.{"ab"}, 3));
    try std.testing.expect(cw.limit_exceeded);
    try std.testing.expectEqual(@as(usize, 0), inner.writer.end);
}

test "CountingWriter.sendFile: clamps the source so a file cannot overshoot the cap" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;

    // Per-random tmp path so concurrent test processes cannot clobber it.
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const path = try std.fmt.allocPrint(alloc, "/tmp/malt_cap_sendfile_{x}", .{std.mem.bytesToValue(u64, &rnd)});
    defer alloc.free(path);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};

    {
        const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "0123456789abcdefghij"); // 20 bytes > cap
    }

    const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    var fbuf: [64]u8 = undefined;
    var fr = f.reader(io, &fbuf);

    var inner: std.Io.Writer.Allocating = .init(alloc);
    defer inner.deinit();
    var cw = HttpClient.CountingWriter{
        .inner = &inner.writer,
        .bytes_written = std.atomic.Value(u64).init(0),
        .max_bytes = 10,
        .limit_exceeded = false,
        .progress = null,
        .content_length = null,
    };

    // Unlimited source over a 20-byte file: the clamp binds the write to the
    // 10-byte cap, so nothing past max_bytes is committed.
    try std.testing.expectEqual(@as(usize, 10), try cw.writer.vtable.sendFile(&cw.writer, &fr, .unlimited));
    try std.testing.expectEqual(@as(usize, 10), inner.writer.end);
    try std.testing.expect(!cw.limit_exceeded);

    // Already at the cap: a further sendFile is refused before touching the source.
    try std.testing.expectError(error.WriteFailed, cw.writer.vtable.sendFile(&cw.writer, &fr, .unlimited));
    try std.testing.expect(cw.limit_exceeded);
    try std.testing.expectEqual(@as(usize, 10), inner.writer.end);
}
