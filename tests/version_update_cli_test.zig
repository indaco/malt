//! malt — `mt version update` dispatch tests.
//!
//! version_update.execute() does network-bound work past the cleanup
//! short-circuit, so the testable surface is the early branches:
//! `--cleanup` (filesystem-only sweep) and the homebrew-origin
//! routing that detects a Homebrew-managed binary and refuses to
//! self-update.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const updater = malt.cli_version_update;
const output = malt.output;

test "execute --cleanup walks update artefacts next to the running binary" {
    // The test binary is the running exe; cleanUpdateArtefacts looks
    // for `<self>.old` and `.malt-update-*` siblings. None of those
    // exist next to the test runner, so the helper takes the
    // "Nothing to clean up" branch and returns Ok.
    output.setQuiet(true);
    defer output.setQuiet(false);

    try updater.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--cleanup"});
}
