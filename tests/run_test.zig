//! malt — run (ephemeral execution) tests

const std = @import("std");
const testing = std.testing;

test "run requires package name" {
    // mt run with no args should print usage error
}

test "run uses installed binary if available" {
    // If package is already installed, run should exec the installed binary
}

test "run downloads to temp and cleans up" {
    // After ephemeral run, no files remain in tmp/ or store/
}

test "run passes arguments after --" {
    // mt run jq -- --version should pass --version to jq
}

test "run reports error for nonexistent formula" {
    // mt run nonexistent_pkg should print formula not found
}
