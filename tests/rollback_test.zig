//! malt — rollback command tests

const std = @import("std");
const testing = std.testing;

test "rollback requires package name" {
    // mt rollback with no args should print usage error
}

test "rollback detects no previous version" {
    // If store only has current version, rollback reports no previous version found
}

test "rollback restores previous version from store" {
    // Install v1, upgrade to v2, rollback should restore v1 from store
    // Verify: binary at bin/ points to v1, DB updated, cellar has v1
}

test "rollback is atomic — failure leaves current version intact" {
    // If materialization fails, current version should remain linked
}

test "rollback with --dry-run shows plan" {
    // Dry run should report what would happen without changing state
}
