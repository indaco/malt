//! malt — offline-mode env resolution.
//! `MALT_OFFLINE` (truthy: `1`, `true`) makes every net/* call route through
//! the snapshot cache and hard-fail with `OfflineRequired` on a miss instead
//! of waiting for a connect timeout. Resolved once at boot so per-call sites
//! consume a single bool instead of re-walking the env.

const std = @import("std");

/// True iff `raw` is one of the accepted truthy spellings. Mirrors the
/// `MALT_OFFLINE=1` / `MALT_OFFLINE=true` shape called out in the task doc;
/// every other value (including the empty string from a leftover
/// `MALT_OFFLINE=` line in a shell rc) reads as off.
pub fn parseTruthy(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "1")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "true")) return true;
    return false;
}

/// Resolve `MALT_OFFLINE` from `environ`. Returns false when the env var
/// is unset or any non-truthy spelling. Pure — no I/O, safe for tests.
pub fn resolveFromEnv(environ: std.process.Environ) bool {
    const raw_z = std.process.Environ.getPosix(environ, "MALT_OFFLINE") orelse return false;
    return parseTruthy(std.mem.sliceTo(raw_z, 0));
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseTruthy accepts 1 and true (case-insensitive)" {
    try testing.expect(parseTruthy("1"));
    try testing.expect(parseTruthy("true"));
    try testing.expect(parseTruthy("TRUE"));
    try testing.expect(parseTruthy("True"));
}

test "parseTruthy rejects 0, false, empty, and unknown spellings" {
    try testing.expect(!parseTruthy("0"));
    try testing.expect(!parseTruthy("false"));
    try testing.expect(!parseTruthy(""));
    try testing.expect(!parseTruthy("yes"));
    try testing.expect(!parseTruthy("on"));
}

test "parseTruthy trims surrounding whitespace before matching" {
    try testing.expect(parseTruthy("  1  "));
    try testing.expect(parseTruthy("\ttrue\n"));
    try testing.expect(!parseTruthy("   "));
}

test "resolveFromEnv returns false on an empty env" {
    try testing.expect(!resolveFromEnv(std.process.Environ.empty));
}

test "resolveFromEnv returns true for MALT_OFFLINE=1" {
    const entries = [_:null]?[*:0]const u8{"MALT_OFFLINE=1".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    try testing.expect(resolveFromEnv(env));
}

test "resolveFromEnv returns true for MALT_OFFLINE=true" {
    const entries = [_:null]?[*:0]const u8{"MALT_OFFLINE=true".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    try testing.expect(resolveFromEnv(env));
}

test "resolveFromEnv treats MALT_OFFLINE=0 as off" {
    const entries = [_:null]?[*:0]const u8{"MALT_OFFLINE=0".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    try testing.expect(!resolveFromEnv(env));
}

test "resolveFromEnv treats a bare MALT_OFFLINE= as off" {
    // A leftover `MALT_OFFLINE=` line in a shell rc must not silently
    // activate the mode — only an explicit truthy value counts.
    const entries = [_:null]?[*:0]const u8{"MALT_OFFLINE=".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    try testing.expect(!resolveFromEnv(env));
}
