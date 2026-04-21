//! malt — upgrade.execute behaviour tests
//! Locks in the exit-code contract: an upgrade that touches a package we
//! cannot upgrade (not installed, or batch item failure) must surface a
//! non-zero exit instead of silently reporting success. Uses a scratch
//! MALT_PREFIX so no real DB or network is hit.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const upgrade = malt.upgrade;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_upgrade_exec_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
        0,
    );
    malt.fs_compat.deleteTreeAbsolute(path) catch {};
    try malt.fs_compat.cwd().makePath(path);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "mt upgrade <nonexistent> surfaces a non-zero exit" {
    const path = try setupPrefix("nonexistent_pkg");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // Seed an empty DB so the `db/` dir exists (lock acquire doesn't
    // short-circuit to silent-return) but no packages are installed.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);

    try testing.expectError(
        error.Aborted,
        upgrade.execute(testing.allocator, &.{"definitely-not-installed"}),
    );
}
