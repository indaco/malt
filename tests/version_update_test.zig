//! malt — version update tests
//! Network-dependent tests deferred. Unit tests cover version parsing.

const std = @import("std");
const testing = std.testing;
const version_mod = @import("malt").version;

test "version value is non-empty and trimmed" {
    try testing.expect(version_mod.value.len > 0);
    // Should not have trailing whitespace
    try testing.expect(version_mod.value[version_mod.value.len - 1] != '\n');
    try testing.expect(version_mod.value[version_mod.value.len - 1] != ' ');
}
