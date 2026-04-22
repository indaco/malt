//! malt — patch facade tests
//!
//! Guards the cross-platform relocation seam. Today the only backend is
//! macOS (`install_name_tool`); a future Linux task drops into the
//! `.linux` arm of the comptime switch with `patchelf`, at which point
//! `external_tool_name` changes and this test is the first thing that
//! fails loud.
//!
//! These tests deliberately reference the facade (`malt.patch`) rather
//! than `malt.patcher` so cellar / doctor callers that do the same keep
//! a honest single-seam rule.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const patch = malt.patch;
const patcher = malt.patcher;

test "facade re-exports the patcher surface cellar / doctor rely on" {
    // If any of these go missing the swap-to-Linux diff is suddenly
    // non-trivial; holding the shape explicit documents what any
    // future backend must provide.
    _ = patch.Replacement;
    _ = patch.PatchOutcome;
    _ = patch.OverflowEntry;
    _ = patch.PatchError;
    _ = patch.FallbackError;
    _ = patch.patchPathsCollecting;
    _ = patch.flushOverflow;
    _ = patch.external_tool_name;
}

test "facade external_tool_name matches the macOS backend" {
    try testing.expectEqualStrings("install_name_tool", patch.external_tool_name);
    try testing.expectEqualStrings(patcher.external_tool_name, patch.external_tool_name);
}

test "facade OverflowEntry / PatchOutcome are identical to the backend's" {
    // Same type-identity means callers can hand outcomes between the
    // facade and the backend without a conversion step.
    try testing.expect(patch.OverflowEntry == patcher.OverflowEntry);
    try testing.expect(patch.PatchOutcome == patcher.PatchOutcome);
}
