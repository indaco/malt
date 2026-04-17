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
