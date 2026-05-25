//! malt — corporate-mirror env resolution.
//! Reads `MALT_API_DOMAIN` / `MALT_BOTTLE_DOMAIN` once (with the
//! `HOMEBREW_*` peers as fallbacks) so every net/* call site can
//! consume a single resolved base URL instead of re-reading the env.
//! HTTPS-only by design: a plaintext mirror would weaken the
//! redirect-downgrade guard in `net/client.zig`.

const std = @import("std");

pub const default_api_base_url: []const u8 = "https://formulae.brew.sh/api";
pub const default_bottle_base_url: []const u8 = "https://ghcr.io";

pub const Error = error{NonHttpsOverride};

/// Process-wide resolved snapshot. Built once by `main` and threaded
/// through `AppCtx`; per-call sites read `api_base` / `bottle_base`
/// directly. The `*_overridden` flags drive `mt doctor`'s mirror row
/// without re-walking the env.
pub const Mirrors = struct {
    api_base: []const u8 = default_api_base_url,
    bottle_base: []const u8 = default_bottle_base_url,
    api_overridden: bool = false,
    bottle_overridden: bool = false,
};

/// True iff `url` is a syntactically valid `https://...` URL. We reject
/// every other scheme — even `http://` — because the redirect guard in
/// `net/client.zig` would otherwise have to relax for mirror traffic.
pub fn isHttpsUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://")) return false;
    return url.len > "https://".len;
}

/// Resolve a single override knob: `primary` wins, `fallback` is read
/// only if `primary` is unset. Returns `null` when neither is set (or
/// when the value is whitespace-only, so a leftover `MALT_API_DOMAIN=`
/// in a shell rc doesn't poison the run). Trims trailing slashes so
/// every URL builder can `{base}/path` without doubling up. Validates
/// HTTPS at the boundary so downstream consumers trust the slice.
fn resolveOverride(
    environ: std.process.Environ,
    primary: []const u8,
    fallback: []const u8,
) Error!?[]const u8 {
    const raw_z = std.process.Environ.getPosix(environ, primary) orelse
        std.process.Environ.getPosix(environ, fallback) orelse
        return null;
    const trimmed = std.mem.trim(u8, std.mem.sliceTo(raw_z, 0), &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    const normalized = std.mem.trimEnd(u8, trimmed, "/");
    if (!isHttpsUrl(normalized)) return Error.NonHttpsOverride;
    return normalized;
}

/// Resolve the metadata-API base URL. Honours `MALT_API_DOMAIN`,
/// falls back to `HOMEBREW_API_DOMAIN`. Returns the default when
/// neither is set.
pub fn resolveApiBase(environ: std.process.Environ) Error![]const u8 {
    const ov = try resolveOverride(environ, "MALT_API_DOMAIN", "HOMEBREW_API_DOMAIN");
    return ov orelse default_api_base_url;
}

/// Resolve the bottle/registry base URL. Honours `MALT_BOTTLE_DOMAIN`,
/// falls back to `HOMEBREW_BOTTLE_DOMAIN`. Returns the default when
/// neither is set.
pub fn resolveBottleBase(environ: std.process.Environ) Error![]const u8 {
    const ov = try resolveOverride(environ, "MALT_BOTTLE_DOMAIN", "HOMEBREW_BOTTLE_DOMAIN");
    return ov orelse default_bottle_base_url;
}

/// One-shot resolution of every mirror knob. Called from `main` after
/// `AppCtx` is built; the result is owned by `AppCtx.mirrors` and the
/// strings borrow from the parent process environ (lifetime ≥ AppCtx).
pub fn resolve(environ: std.process.Environ) Error!Mirrors {
    const api_ov = try resolveOverride(environ, "MALT_API_DOMAIN", "HOMEBREW_API_DOMAIN");
    const bot_ov = try resolveOverride(environ, "MALT_BOTTLE_DOMAIN", "HOMEBREW_BOTTLE_DOMAIN");
    return .{
        .api_base = api_ov orelse default_api_base_url,
        .bottle_base = bot_ov orelse default_bottle_base_url,
        .api_overridden = api_ov != null,
        .bottle_overridden = bot_ov != null,
    };
}

/// Best-effort host probe URL for `mt doctor`'s API-reachable check.
/// Strips the path component so a HEAD on `<scheme>://<host>` exercises
/// the mirror endpoint without paying for `/formula.json`. Leaves
/// host-only URLs untouched.
pub fn hostProbeUrl(base_url: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, base_url, "https://")) return base_url;
    const after = base_url["https://".len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return base_url;
    return base_url[0 .. "https://".len + slash];
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "isHttpsUrl accepts https URLs with a host" {
    try testing.expect(isHttpsUrl("https://example.com"));
    try testing.expect(isHttpsUrl("https://example.com/api"));
    try testing.expect(isHttpsUrl("https://example.com:8443/path"));
}

test "isHttpsUrl rejects every non-https scheme" {
    try testing.expect(!isHttpsUrl("http://example.com"));
    try testing.expect(!isHttpsUrl("ftp://example.com"));
    try testing.expect(!isHttpsUrl("ws://example.com"));
    try testing.expect(!isHttpsUrl(""));
    try testing.expect(!isHttpsUrl("https://"));
}

test "resolveApiBase returns the default when no env is set" {
    const got = try resolveApiBase(std.process.Environ.empty);
    try testing.expectEqualStrings(default_api_base_url, got);
}

test "resolveApiBase honours MALT_API_DOMAIN" {
    const entries = [_:null]?[*:0]const u8{"MALT_API_DOMAIN=https://mirror.example.com/api".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const got = try resolveApiBase(env);
    try testing.expectEqualStrings("https://mirror.example.com/api", got);
}

test "resolveApiBase falls back to HOMEBREW_API_DOMAIN" {
    const entries = [_:null]?[*:0]const u8{"HOMEBREW_API_DOMAIN=https://hb-mirror.example.com/api".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const got = try resolveApiBase(env);
    try testing.expectEqualStrings("https://hb-mirror.example.com/api", got);
}

test "resolveApiBase prefers MALT_* over HOMEBREW_* when both are set" {
    const entries = [_:null]?[*:0]const u8{
        "MALT_API_DOMAIN=https://malt.example.com/api".ptr,
        "HOMEBREW_API_DOMAIN=https://hb.example.com/api".ptr,
    };
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..2 :null] } };
    const got = try resolveApiBase(env);
    try testing.expectEqualStrings("https://malt.example.com/api", got);
}

test "resolveApiBase rejects non-https overrides" {
    const entries = [_:null]?[*:0]const u8{"MALT_API_DOMAIN=http://insecure.example.com/api".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    try testing.expectError(Error.NonHttpsOverride, resolveApiBase(env));
}

test "resolveApiBase treats an empty value as unset and returns the default" {
    const entries = [_:null]?[*:0]const u8{"MALT_API_DOMAIN=".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const got = try resolveApiBase(env);
    try testing.expectEqualStrings(default_api_base_url, got);
}

test "resolveApiBase treats whitespace-only as unset" {
    // A leftover `MALT_API_DOMAIN=   ` line in a shell rc must not
    // surface as NonHttpsOverride — that error confuses operators who
    // never intended to set the knob.
    const entries = [_:null]?[*:0]const u8{"MALT_API_DOMAIN=   \t".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const got = try resolveApiBase(env);
    try testing.expectEqualStrings(default_api_base_url, got);
}

test "resolveApiBase strips trailing slashes so URL builders don't double up" {
    const entries = [_:null]?[*:0]const u8{"MALT_API_DOMAIN=https://mirror.example.com/api/".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const got = try resolveApiBase(env);
    try testing.expectEqualStrings("https://mirror.example.com/api", got);
}

test "resolveApiBase strips multiple trailing slashes" {
    const entries = [_:null]?[*:0]const u8{"MALT_API_DOMAIN=https://mirror.example.com/api///".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const got = try resolveApiBase(env);
    try testing.expectEqualStrings("https://mirror.example.com/api", got);
}

test "resolveApiBase trims surrounding whitespace before validation" {
    const entries = [_:null]?[*:0]const u8{"MALT_API_DOMAIN=  https://mirror.example.com/api  ".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const got = try resolveApiBase(env);
    try testing.expectEqualStrings("https://mirror.example.com/api", got);
}

test "resolveBottleBase strips trailing slashes" {
    // GHCR blob URLs are built as `{base}/v2/{repo}/blobs/{digest}` —
    // a trailing slash on `base` would land a `//v2/...` path that
    // most registries serve as 404.
    const entries = [_:null]?[*:0]const u8{"MALT_BOTTLE_DOMAIN=https://reg.example.com/".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const got = try resolveBottleBase(env);
    try testing.expectEqualStrings("https://reg.example.com", got);
}

test "resolveBottleBase returns the default when no env is set" {
    const got = try resolveBottleBase(std.process.Environ.empty);
    try testing.expectEqualStrings(default_bottle_base_url, got);
}

test "resolveBottleBase honours MALT_BOTTLE_DOMAIN" {
    const entries = [_:null]?[*:0]const u8{"MALT_BOTTLE_DOMAIN=https://reg.example.com".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const got = try resolveBottleBase(env);
    try testing.expectEqualStrings("https://reg.example.com", got);
}

test "resolveBottleBase falls back to HOMEBREW_BOTTLE_DOMAIN" {
    const entries = [_:null]?[*:0]const u8{"HOMEBREW_BOTTLE_DOMAIN=https://hb-reg.example.com".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const got = try resolveBottleBase(env);
    try testing.expectEqualStrings("https://hb-reg.example.com", got);
}

test "resolveBottleBase prefers MALT_* over HOMEBREW_*" {
    const entries = [_:null]?[*:0]const u8{
        "MALT_BOTTLE_DOMAIN=https://malt-reg.example.com".ptr,
        "HOMEBREW_BOTTLE_DOMAIN=https://hb-reg.example.com".ptr,
    };
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..2 :null] } };
    const got = try resolveBottleBase(env);
    try testing.expectEqualStrings("https://malt-reg.example.com", got);
}

test "resolveBottleBase rejects non-https overrides" {
    const entries = [_:null]?[*:0]const u8{"MALT_BOTTLE_DOMAIN=http://reg.example.com".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    try testing.expectError(Error.NonHttpsOverride, resolveBottleBase(env));
}

test "resolve returns defaults with both *_overridden flags false on empty env" {
    const got = try resolve(std.process.Environ.empty);
    try testing.expectEqualStrings(default_api_base_url, got.api_base);
    try testing.expectEqualStrings(default_bottle_base_url, got.bottle_base);
    try testing.expect(!got.api_overridden);
    try testing.expect(!got.bottle_overridden);
}

test "resolve flags overridden bases when both env knobs are set" {
    const entries = [_:null]?[*:0]const u8{
        "MALT_API_DOMAIN=https://m-api.example.com".ptr,
        "MALT_BOTTLE_DOMAIN=https://m-reg.example.com".ptr,
    };
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..2 :null] } };
    const got = try resolve(env);
    try testing.expectEqualStrings("https://m-api.example.com", got.api_base);
    try testing.expectEqualStrings("https://m-reg.example.com", got.bottle_base);
    try testing.expect(got.api_overridden);
    try testing.expect(got.bottle_overridden);
}

test "resolve surfaces a non-https override regardless of which knob trips it" {
    const entries = [_:null]?[*:0]const u8{"MALT_BOTTLE_DOMAIN=http://reg.example.com".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    try testing.expectError(Error.NonHttpsOverride, resolve(env));
}

test "hostProbeUrl strips the path component" {
    try testing.expectEqualStrings("https://formulae.brew.sh", hostProbeUrl("https://formulae.brew.sh/api"));
    try testing.expectEqualStrings("https://mirror.example.com:8443", hostProbeUrl("https://mirror.example.com:8443/path/extra"));
}

test "hostProbeUrl is a no-op for host-only URLs" {
    try testing.expectEqualStrings("https://example.com", hostProbeUrl("https://example.com"));
}

test "hostProbeUrl leaves non-https inputs untouched (defensive)" {
    // We never feed non-https URLs in production (the resolver rejects
    // them), but the helper stays total so a future caller can't trip
    // an unreachable.
    try testing.expectEqualStrings("ftp://example.com/x", hostProbeUrl("ftp://example.com/x"));
}
