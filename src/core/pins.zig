//! malt — pinned homebrew-core source integrity
//!
//! Ruby formula sources fetched from GitHub over the wire are untrusted
//! until verified. This module ships (a) a compile-time-embedded commit
//! SHA identifying the snapshot of homebrew-core this release of malt
//! was built against, and (b) an embedded manifest mapping formula name
//! -> expected SHA256 of the .rb blob at that commit. The fetch path in
//! ruby_subprocess.zig uses both to refuse anything outside this pin.
//!
//! Regenerate with `scripts/gen-pins.sh` whenever the pinned commit
//! bumps — the release should never ship with a stale pin.

const std = @import("std");

/// Pinned homebrew-core commit. Floating `HEAD` gave every release a
/// TOFU window against a silent upstream rewrite; this constant nails
/// the fetch URL to a single tree an auditor can reproduce.
///
/// Bump at release time via `scripts/gen-pins.sh`.
pub const HOMEBREW_CORE_COMMIT_SHA: []const u8 = "5d3790f92c7873f1fd8e5e2ecd6fbc689a78a96f";

const MANIFEST_TEXT: []const u8 = @embedFile("pins_manifest.txt");

/// Length of a lowercase hex SHA256 digest.
pub const SHA256_HEX_LEN: usize = 64;

/// Look up the expected SHA256 (as lowercase hex) for a formula at the
/// pinned commit. Returns null when no entry exists — the caller must
/// treat "no entry" as a refusal, not a pass-through.
///
/// Linear scan: the manifest is in the thousands of bytes and this
/// function is hit at most once per formula install, behind a network
/// round-trip, so a StringHashMap would cost more than it saves.
pub fn expectedSha256(name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    var it = std.mem.splitScalar(u8, MANIFEST_TEXT, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Split on the first run of whitespace. Names are
        // [a-z0-9@._+-], so any space/tab ends the name field.
        const sep = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const entry_name = line[0..sep];
        if (!std.mem.eql(u8, entry_name, name)) continue;

        const rest = std.mem.trimStart(u8, line[sep..], " \t");
        if (rest.len < SHA256_HEX_LEN) return null;
        const hash = rest[0..SHA256_HEX_LEN];
        if (!isHexLower(hash)) return null;
        return hash;
    }
    return null;
}

fn isHexLower(s: []const u8) bool {
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Compute the SHA256 of `bytes` as lowercase hex. Returns the caller-
/// owned `[SHA256_HEX_LEN]u8` written in-place to `out`.
pub fn sha256Hex(bytes: []const u8, out: *[SHA256_HEX_LEN]u8) void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out, hex[0..]);
}

test "expectedSha256 — missing entry returns null" {
    try std.testing.expectEqual(@as(?[]const u8, null), expectedSha256("definitely-not-in-manifest"));
    try std.testing.expectEqual(@as(?[]const u8, null), expectedSha256(""));
}

test "expectedSha256 — comment/blank tolerant parser" {
    // This test exercises the parser shape. The manifest ships empty by
    // default (header-only), so we confirm lookup-on-empty returns null
    // without crashing on the comment lines.
    try std.testing.expectEqual(@as(?[]const u8, null), expectedSha256("fontconfig"));
}

test "sha256Hex — known vector" {
    var out: [SHA256_HEX_LEN]u8 = undefined;
    sha256Hex("hello", &out);
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &out,
    );
}
