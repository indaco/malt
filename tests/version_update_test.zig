//! malt — version update tests.
//!
//! Matcher / walker coverage moved to tests/release_test.zig alongside
//! the `src/update/release.zig` module. This file now only pins the
//! version-string sanity guard.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const version_mod = malt.version;

test "version value is non-empty and trimmed" {
    try testing.expect(version_mod.value.len > 0);
    try testing.expect(version_mod.value[version_mod.value.len - 1] != '\n');
    try testing.expect(version_mod.value[version_mod.value.len - 1] != ' ');
}
