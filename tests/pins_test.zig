//! malt — pins module tests
//!
//! Covers the manifest parser and SHA helper used by the pinned
//! homebrew-core fetch path (`ruby_subprocess.fetchPostInstallFromGitHub`).
//! Intentionally does no network: the fetch path itself is guarded by
//! manifest lookup, and `expectedSha256` is the load-bearing check.

const std = @import("std");
const testing = std.testing;
const pins = @import("malt").pins;

test "HOMEBREW_CORE_COMMIT_SHA is a 40-char lowercase hex digest" {
    const sha = pins.HOMEBREW_CORE_COMMIT_SHA;
    try testing.expectEqual(@as(usize, 40), sha.len);
    for (sha) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return error.TestUnexpectedResult,
    };
}

test "expectedSha256 rejects unknown formula" {
    try testing.expectEqual(@as(?[]const u8, null), pins.expectedSha256("definitely-not-here-xyz"));
}

test "expectedSha256 rejects empty name" {
    try testing.expectEqual(@as(?[]const u8, null), pins.expectedSha256(""));
}

test "sha256Hex — empty input matches SHA256('')" {
    var out: [pins.SHA256_HEX_LEN]u8 = undefined;
    pins.sha256Hex("", &out);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &out,
    );
}

test "sha256Hex — short known vector" {
    var out: [pins.SHA256_HEX_LEN]u8 = undefined;
    pins.sha256Hex("abc", &out);
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &out,
    );
}

// ────────────────────────────────────────────────────────────────────
// Manifest parser edge cases. These run against an in-memory fixture
// via `lookupIn` so they can't be masked by a well-formed shipping
// manifest — each one isolates one property of the parser.
// ────────────────────────────────────────────────────────────────────

const good_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

test "lookupIn — space-separated entry found" {
    const m = "fontconfig " ++ good_hash ++ "\n";
    const h = pins.lookupIn(m, "fontconfig") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(good_hash, h);
}

test "lookupIn — tab-separated entry found" {
    const m = "fontconfig\t" ++ good_hash ++ "\n";
    const h = pins.lookupIn(m, "fontconfig") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(good_hash, h);
}

test "lookupIn — blank lines and comments are ignored" {
    const m =
        "\n" ++
        "# comment\n" ++
        "  # indented comment\n" ++
        "\n" ++
        "node " ++ good_hash ++ "\n";
    const h = pins.lookupIn(m, "node") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(good_hash, h);
}

test "lookupIn — uppercase hex rejected" {
    const bad = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const m = "node " ++ bad ++ "\n";
    try testing.expectEqual(@as(?[]const u8, null), pins.lookupIn(m, "node"));
}

test "lookupIn — non-hex chars rejected" {
    const bad = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
    const m = "node " ++ bad ++ "\n";
    try testing.expectEqual(@as(?[]const u8, null), pins.lookupIn(m, "node"));
}

test "lookupIn — short hash rejected" {
    const m = "node deadbeef\n";
    try testing.expectEqual(@as(?[]const u8, null), pins.lookupIn(m, "node"));
}

test "lookupIn — name-without-hash line skipped" {
    const m = "badline\ngood " ++ good_hash ++ "\n";
    try testing.expectEqual(@as(?[]const u8, null), pins.lookupIn(m, "badline"));
    const h = pins.lookupIn(m, "good") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(good_hash, h);
}

test "lookupIn — substring-of-name does NOT match" {
    // pathological case: don't let `nodejs` accidentally satisfy a query
    // for `node`.
    const m = "nodejs " ++ good_hash ++ "\n";
    try testing.expectEqual(@as(?[]const u8, null), pins.lookupIn(m, "node"));
}

test "lookupIn — first match wins when name appears twice" {
    const h1 = "1111111111111111111111111111111111111111111111111111111111111111";
    const h2 = "2222222222222222222222222222222222222222222222222222222222222222";
    const m = "node " ++ h1 ++ "\nnode " ++ h2 ++ "\n";
    const got = pins.lookupIn(m, "node") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(h1, got);
}

test "lookupIn — CRLF line endings tolerated" {
    const m = "node " ++ good_hash ++ "\r\n";
    const h = pins.lookupIn(m, "node") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(good_hash, h);
}

test "lookupIn — trailing text after hash ignored (length gate)" {
    // lookupIn slices exactly SHA256_HEX_LEN chars; anything after is
    // out of bounds of the returned hash but mustn't crash the parser.
    const m = "node " ++ good_hash ++ "  # with comment\n";
    const h = pins.lookupIn(m, "node") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(good_hash, h);
}
