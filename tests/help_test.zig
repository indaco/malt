//! malt — CLI help module tests
//! Covers showIfRequested flag detection and the helpFor lookup table.

const std = @import("std");
const testing = std.testing;

const help = @import("malt").cli_help;
const malt = @import("malt");
const test_io = @import("test_io");

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
        "install",  "uninstall",   "upgrade",            "update",
        "outdated", "list",        "info",               "search",
        "doctor",   "tap",         "migrate",            "rollback",
        "run",      "link",        "unlink",             "pin",
        "unpin",    "completions", "backup",             "restore",
        "purge",    "tui",         "not-a-real-command",
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

test "outdated help documents --tap and notes the tap-equality rule" {
    // Discoverability guard: the flag only meaningfully exists if the
    // help output advertises it and warns about strict-equality (legacy
    // casks with NULL tap silently miss the filter).
    const text = help.helpFor("outdated");
    try testing.expect(std.mem.indexOf(u8, text, "--tap") != null);
    try testing.expect(std.mem.indexOf(u8, text, "user/repo") != null);
}

test "deps help documents --recursive, --installed, and --json" {
    // Discoverability guard: deps is the forward complement of `uses`,
    // and the three flags below define what the command can do beyond
    // a single direct read. Drop one from --help and users won't know.
    const text = help.helpFor("deps");
    try testing.expect(std.mem.indexOf(u8, text, "--recursive") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--installed") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--json") != null);
}

test "install/upgrade/reinstall help documents --isolate-deps" {
    // Discoverability guard for the dep-bin isolation feature: a user
    // can't opt into a flag they can't find in --help. The contract
    // must be visible on every install-flavoured verb.
    inline for (&[_][]const u8{ "install", "upgrade", "reinstall" }) |verb| {
        const text = help.helpFor(verb);
        try testing.expect(std.mem.indexOf(u8, text, "--isolate-deps") != null);
    }
}

test "link help documents --isolate and --all" {
    const text = help.helpFor("link");
    try testing.expect(std.mem.indexOf(u8, text, "--isolate") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--all") != null);
}

test "tui help documents the tabs, keybindings, delegation, and the non-TTY refusal" {
    // Discoverability guard: `mt tui --help` is the user's map to the dashboard.
    // It has to name the tab set, the keys, the delegation model, why it refuses
    // a non-interactive terminal (exit 2) rather than emit a corrupt frame, and
    // the MALT_THEME knob.
    const text = help.helpFor("tui");
    try testing.expect(std.mem.indexOf(u8, text, "malt tui") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Search") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Doctor") != null);
    try testing.expect(std.mem.indexOf(u8, text, "resize") != null);
    try testing.expect(std.mem.indexOf(u8, text, "delegate") != null);
    try testing.expect(std.mem.indexOf(u8, text, "exit 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "MALT_THEME") != null);
}

test "helpFor falls back gracefully for unknown commands" {
    try testing.expectEqualStrings("No help available.\n", help.helpFor("not-a-real-command"));
}

test "cleanup help advertises the shorthand and points at purge" {
    // `mt cleanup` is a thin alias; --help has to make that explicit so
    // users discover the full scope menu lives under `mt purge`.
    const text = help.helpFor("cleanup");
    try testing.expect(std.mem.indexOf(u8, text, "malt cleanup") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--housekeeping") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mt purge") != null);
}

test "showIfRequested honours --help for cleanup" {
    const ctx = quietCtx();
    const args = [_][]const u8{"--help"};
    try testing.expect(help.showIfRequested(&ctx, &args, "cleanup"));
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
