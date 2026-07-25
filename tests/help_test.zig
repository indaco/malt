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

/// `--version` prints the version and never reaches a topic lookup, so it is
/// the one name in the block that is not expected to resolve. `-h`/`--help` do
/// reach it, because `malt help -h` passes the spelling through verbatim.
const not_topics = [_][]const u8{"--version"};

/// Extract every argv spelling from `main.zig`'s `command_names` block. The old
/// guard hand-listed command strings and asserted `showIfRequested` returned
/// true, which it does even when the lookup falls through to the stub, so it
/// could never catch a missing map entry. Deriving the list from the dispatcher
/// means a command added tomorrow is covered the day it lands.
fn commandNames(allocator: std.mem.Allocator, src: []const u8) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);

    const block_start = std.mem.indexOf(u8, src, "const command_names = [_]struct {") orelse
        return error.MissingCommandNames;
    var rest = src[block_start..];
    const block_end = std.mem.indexOf(u8, rest, "\n};") orelse return error.MissingCommandNames;
    rest = rest[0..block_end];

    var lines = std.mem.splitScalar(u8, rest, '\n');
    while (lines.next()) |line| {
        const list_start = std.mem.indexOf(u8, line, ".names = &.{") orelse continue;
        var tail = line[list_start..];
        while (std.mem.indexOfScalar(u8, tail, '"')) |open| {
            tail = tail[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, tail, '"') orelse break;
            try names.append(allocator, tail[0..close]);
            tail = tail[close + 1 ..];
        }
    }
    return names;
}

test "every command name the dispatcher accepts has a real help topic" {
    const allocator = testing.allocator;

    const f = try test_io.cwd().openFile(std.Options.debug_io, "src/main.zig", .{});
    defer f.close(std.Options.debug_io);
    const src = try test_io.readFileToEndAlloc(f, allocator, 4 * 1024 * 1024);
    defer allocator.free(src);

    var names = try commandNames(allocator, src);
    defer names.deinit(allocator);

    // A vanished or renamed block must fail loudly, not pass vacuously.
    try testing.expect(names.items.len > 25);

    for (names.items) |name| {
        var skip = false;
        for (not_topics) |n| skip = skip or std.mem.eql(u8, n, name);
        if (skip) continue;
        try testing.expect(!std.mem.eql(u8, help.helpFor(name), "No help available.\n"));
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

test "version help documents the update subcommand and its flags" {
    const text = help.helpFor("version");
    try testing.expect(std.mem.indexOf(u8, text, "malt version") != null);
    try testing.expect(std.mem.indexOf(u8, text, "update") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--check") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--cleanup") != null);
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

// Integration: `malt help <cmd>` must show that command's help topic,
// not the general usage. Relies on the pre-built binary; skipped if absent.
test "help command routes its argument to the per-command topic" {
    const io = std.Options.debug_io;
    const bin_path = "zig-out/bin/malt";
    test_io.cwd().access(io, bin_path, .{}) catch return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = &[_][]const u8{ bin_path, "help", "install" },
        .stdout_limit = .limited(1 << 16),
        .stderr_limit = .limited(1 << 16),
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Usage: malt install") != null);
}

// Integration: an unknown help topic degrades to the stock fallback and
// still exits 0 — help must never fail. Skipped if the binary is absent.
test "help command falls back gracefully for unknown topics" {
    const io = std.Options.debug_io;
    const bin_path = "zig-out/bin/malt";
    test_io.cwd().access(io, bin_path, .{}) catch return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = &[_][]const u8{ bin_path, "help", "not-a-real-command" },
        .stdout_limit = .limited(1 << 16),
        .stderr_limit = .limited(1 << 16),
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "No help available.") != null);
}

test "bundle and services have help topics" {
    // Both commands used to own a local printHelp, so `malt help bundle` fell
    // through to the generic "No help available" fallback while `--help`
    // worked. One text, reachable both ways.
    try testing.expect(std.mem.indexOf(u8, help.helpFor("bundle"), "malt bundle") != null);
    try testing.expect(std.mem.indexOf(u8, help.helpFor("bundle"), "--purge") != null);
    try testing.expect(std.mem.indexOf(u8, help.helpFor("services"), "malt services") != null);
    try testing.expect(std.mem.indexOf(u8, help.helpFor("services"), "restart") != null);
}

test "uninstall help no longer advertises the unimplemented --zap" {
    // --zap promised a cask deep clean that no parser ever read, so running it
    // silently did nothing while implying preferences and caches were removed.
    // Nothing parses a cask `zap` stanza yet, so the honest state is silence.
    try testing.expect(std.mem.indexOf(u8, help.helpFor("uninstall"), "--zap") == null);
}

test "upgrade help no longer advertises the no-op --all" {
    // A nameless `upgrade` already does formulas + casks, so --all could only
    // ever mean "the default". It is not a Homebrew flag either - `brew upgrade
    // --all` errors with "invalid option" - so there was no compatibility to
    // preserve, just a line implying the default is narrower than it is.
    try testing.expect(std.mem.indexOf(u8, help.helpFor("upgrade"), "--all") == null);
}
