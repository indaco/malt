//! malt — CLI help module tests
//! Covers showIfRequested flag detection and the helpFor lookup table.

const std = @import("std");
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
