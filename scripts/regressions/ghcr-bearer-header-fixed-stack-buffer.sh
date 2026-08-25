#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# Must live at the repo root: ghcr.zig's relative sibling imports
# (client.zig, client_pool.zig, mirror.zig) only resolve from inside
# the source tree's module boundary.
HARNESS="$ROOT/.ghcr-bearer-header-regression.$$.zig"
trap 'rm -f "$HARNESS"' EXIT

cat >"$HARNESS" <<'ZIG'
const std = @import("std");
const client = @import("src/net/client.zig");
const ghcr = @import("src/net/ghcr.zig");

// A batch install mints one token covering every repo, so token length grows
// with batch size. The base URL is a closed port: a header that was built
// surfaces as DownloadFailed, OutOfMemory means it never was.
test "an oversized multi-scope token still reaches the transport" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var inner: std.http.Client = .{ .allocator = a, .io = io };
    var http = client.HttpClient.initWith(&inner, io, std.process.Environ.empty, a);
    defer http.deinit();

    var g = ghcr.GhcrClient.init(io, a, &http);
    defer g.deinit();
    g.base_url = "http://127.0.0.1:1";

    const big = try a.alloc(u8, 2100);
    @memset(big, 'A');
    g.cached_token = big;
    const scope = try a.dupe(u8, "homebrew/core/tree");
    try g.cached_scopes.put(a, scope, {});
    g.token_expiry = std.math.maxInt(i64);

    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();

    const result = g.downloadBlob(&http, "homebrew/core/tree", "sha256:abc", &sink.writer, null);
    try std.testing.expectError(ghcr.GhcrError.DownloadFailed, result);
}
ZIG

if (cd "$ROOT" && zig test --test-filter "oversized multi-scope token" "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: downloadBlob builds the Bearer header at exact size"
else
  echo "FAIL: downloadBlob rejected an oversized token as OutOfMemory (fixed-size auth buffer)" >&2
  exit 1
fi
