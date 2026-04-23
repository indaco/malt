//! malt — core/child runOrFail helper tests.

const std = @import("std");
const malt = @import("malt");
const child_mod = malt.child;

test "runOrFail returns void on exit code 0" {
    const argv = [_][]const u8{ "/bin/sh", "-c", "exit 0" };
    try child_mod.runOrFail(std.testing.allocator, &argv);
}

test "runOrFail returns NonZeroExit on exit code 42" {
    const argv = [_][]const u8{ "/bin/sh", "-c", "exit 42" };
    try std.testing.expectError(
        child_mod.ChildError.NonZeroExit,
        child_mod.runOrFail(std.testing.allocator, &argv),
    );
}

test "runOrFail returns SpawnFailed when program does not exist" {
    const argv = [_][]const u8{"/nonexistent/binary/malt_child_test"};
    try std.testing.expectError(
        child_mod.ChildError.SpawnFailed,
        child_mod.runOrFail(std.testing.allocator, &argv),
    );
}
