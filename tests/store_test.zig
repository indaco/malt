//! malt — store module tests
//! Tests for content-addressable store operations.

const std = @import("std");
const testing = std.testing;

test "commit moves tmp to store atomically" {
    // TODO: create a tmp dir, commit it, verify it appears in store/
}

test "exists returns false for missing entry" {
    // TODO: query a non-existent SHA256, expect false
}

test "remove deletes store entry" {
    // TODO: create entry, remove it, verify gone
}

test "duplicate commit is idempotent" {
    // TODO: committing the same SHA256 twice should succeed
}
