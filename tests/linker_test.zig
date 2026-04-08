//! malt — linker module tests
//! Tests for symlink creation, conflict detection, and unlinking.

const std = @import("std");
const testing = std.testing;

test "link creates symlinks in prefix directories" {
    // TODO: link a keg, verify symlinks in bin/, lib/
}

test "detect link conflicts with existing keg" {
    // TODO: two kegs providing the same binary should conflict
}

test "unlink removes all symlinks for a keg" {
    // TODO: link then unlink, verify all symlinks removed
}

test "keg-only formulas are not linked" {
    // TODO: verify keg_only=true formulas skip linking
}
