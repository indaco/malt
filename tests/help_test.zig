//! malt — CLI help module tests
//! Covers showIfRequested flag detection and the helpFor lookup table.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const help = @import("malt").cli_help;

fn quietCtx() malt.app_ctx.AppCtx {
    return .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };
}

test "showIfRequested returns false when -h/--help absent" {
    const ctx = quietCtx();
    const args = [_][]const u8{ "install", "wget" };
    try testing.expect(!help.showIfRequested(&ctx, &args, "install"));
}

test "showIfRequested returns true for short -h" {
    // Writes help text into the test-sink ctx so it does not corrupt the IPC pipe.
    const ctx = quietCtx();
    const args = [_][]const u8{"-h"};
    try testing.expect(help.showIfRequested(&ctx, &args, "install"));
}

test "showIfRequested returns true for long --help" {
    const ctx = quietCtx();
    const args = [_][]const u8{"--help"};
    try testing.expect(help.showIfRequested(&ctx, &args, "purge"));
}

test "showIfRequested covers every documented command (exercises every branch of the static map)" {
    const ctx = quietCtx();
    const commands = [_][]const u8{
        "install",  "uninstall",          "upgrade", "update",
        "outdated", "list",               "info",    "search",
        "doctor",   "tap",                "migrate", "rollback",
        "run",      "link",               "unlink",  "pin",
        "unpin",    "completions",        "backup",  "restore",
        "purge",    "not-a-real-command",
    };
    const args = [_][]const u8{"--help"};
    for (commands) |cmd| {
        try testing.expect(help.showIfRequested(&ctx, &args, cmd));
    }
}

test "helpFor returns command-specific text for known commands" {
    try testing.expect(std.mem.indexOf(u8, help.helpFor("install"), "malt install") != null);
    try testing.expect(std.mem.indexOf(u8, help.helpFor("rollback"), "malt rollback") != null);
    try testing.expect(std.mem.indexOf(u8, help.helpFor("purge"), "--housekeeping") != null);
}

test "purge help documents --verbose for full per-scope listings" {
    // Discoverability guard: the housekeeping output truncates lists by
    // default, so the bypass flag only exists if --help mentions it.
    const text = help.helpFor("purge");
    try testing.expect(std.mem.indexOf(u8, text, "--verbose") != null);
    try testing.expect(std.mem.indexOf(u8, text, "no truncation") != null);
}

test "purge help documents structured output for scripts" {
    // Discoverability guard: the JSON / NDJSON contract is silent on
    // stdout by default, so users only know to script against it if
    // --help advertises both modes.
    const text = help.helpFor("purge");
    try testing.expect(std.mem.indexOf(u8, text, "--json") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--output-format=ndjson") != null);
}

test "install help documents --local and its code-exec warning" {
    // Discoverability guard: the flag only meaningfully exists if the
    // help output tells the user about it.
    const text = help.helpFor("install");
    try testing.expect(std.mem.indexOf(u8, text, "--local") != null);
    try testing.expect(std.mem.indexOf(u8, text, "trust") != null);
}

test "helpFor falls back gracefully for unknown commands" {
    try testing.expectEqualStrings("No help available.\n", help.helpFor("not-a-real-command"));
}

// Integration: verify that `malt <cmd> --help` writes to stdout (not stderr).
// Relies on the pre-built binary under zig-out/bin/malt; skipped if absent.
test "--help output lands on stdout, not stderr" {
    const io = std.Options.debug_io;
    const bin_path = "zig-out/bin/malt";
    test_io.cwd().access(io, bin_path, .{}) catch return error.SkipZigTest;

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
