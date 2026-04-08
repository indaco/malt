//! malt — dependency resolution tests
//! Tests for topological sort, cycle detection, and orphan finding.

const std = @import("std");
const testing = std.testing;

test "resolve linear dependency chain" {
    // TODO: A -> B -> C should produce [C, B, A]
}

test "detect circular dependency" {
    // TODO: A -> B -> A should report a cycle
}

test "skip already-installed dependencies" {
    // TODO: if B is installed, A -> B should produce [A] only
}

test "find orphaned dependencies" {
    // TODO: deps not needed by any direct install should be listed
}
