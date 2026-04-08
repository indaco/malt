//! malt — formula module tests
//! Tests for formula JSON parsing, alias resolution, and bottle selection.

const std = @import("std");
const testing = std.testing;

test "parse minimal formula JSON" {
    // TODO: parse a minimal formula JSON blob and verify fields
}

test "resolve bottle for current platform" {
    // TODO: given a parsed formula, resolve the correct bottle for arm64/x86_64
}

test "resolve formula alias" {
    // TODO: verify that pkg-config resolves to pkgconf
}

test "handle missing bottle for platform" {
    // TODO: verify error when no bottle matches current arch
}
