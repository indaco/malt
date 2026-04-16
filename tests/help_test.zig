//! malt — CLI help module tests
//! Covers showIfRequested flag detection and the helpFor lookup table.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const help = @import("malt").cli_help;

test "showIfRequested returns false when -h/--help absent" {
    const args = [_][]const u8{ "install", "wget" };
    try testing.expect(!help.showIfRequested(&args, "install"));
}

test "showIfRequested returns true for short -h" {
    // NOTE: this writes the help text to stderr as a side effect; that's
    // fine for kcov and is silenced by zig test runners.
    const args = [_][]const u8{"-h"};
    try testing.expect(help.showIfRequested(&args, "install"));
}

test "showIfRequested returns true for long --help" {
    const args = [_][]const u8{"--help"};
    try testing.expect(help.showIfRequested(&args, "purge"));
}

test "showIfRequested covers every documented command (exercises every branch of the static map)" {
    const commands = [_][]const u8{
        "install",  "uninstall", "upgrade", "update",
        "outdated", "list",      "info",    "search",
        "doctor",   "tap",       "migrate", "rollback",
        "run",      "link",      "unlink",  "completions",
        "backup",   "restore",   "purge",   "not-a-real-command",
    };
    const args = [_][]const u8{"--help"};
    for (commands) |cmd| {
        try testing.expect(help.showIfRequested(&args, cmd));
    }
}

test "helpFor returns command-specific text for known commands" {
    try testing.expect(std.mem.indexOf(u8, help.helpFor("install"), "malt install") != null);
    try testing.expect(std.mem.indexOf(u8, help.helpFor("rollback"), "malt rollback") != null);
    try testing.expect(std.mem.indexOf(u8, help.helpFor("purge"), "--housekeeping") != null);
}

test "helpFor falls back gracefully for unknown commands" {
    try testing.expectEqualStrings("No help available.\n", help.helpFor("not-a-real-command"));
}

// Integration: verify that `malt <cmd> --help` writes to stdout (not stderr).
// Relies on the pre-built binary under zig-out/bin/malt; skipped if absent.
test "--help output lands on stdout, not stderr" {
    const bin_path = "zig-out/bin/malt";
    malt.fs_compat.cwd().access(bin_path, .{}) catch return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = &[_][]const u8{ bin_path, "install", "--help" },
        .stdout_limit = .limited(1 << 16),
        .stderr_limit = .limited(1 << 16),
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try testing.expect(result.stdout.len > 0);
    try testing.expectEqual(@as(usize, 0), result.stderr.len);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "malt install") != null);
}
