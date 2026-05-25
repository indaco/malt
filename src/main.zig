//! malt — macOS package manager
//! CLI entry point and command dispatch for the `mt` binary.

const std = @import("std");

const AppCtx = @import("app_ctx.zig").AppCtx;
const backup = @import("cli/backup.zig");
const bundle = @import("cli/bundle.zig");
const completions = @import("cli/completions.zig");
const deps_cmd = @import("cli/deps.zig");
const doctor = @import("cli/doctor.zig");
const info = @import("cli/info.zig");
const install = @import("cli/install.zig");
const link_cmd = @import("cli/link.zig");
const list = @import("cli/list.zig");
const migrate = @import("cli/migrate.zig");
const outdated = @import("cli/outdated.zig");
const pin_cmd = @import("cli/pin.zig");
const purge = @import("cli/purge.zig");
const restore = @import("cli/restore.zig");
const rollback = @import("cli/rollback.zig");
const run_cmd = @import("cli/run.zig");
const search = @import("cli/search.zig");
const services = @import("cli/services.zig");
const shellenv = @import("cli/shellenv.zig");
const tap = @import("cli/tap.zig");
const uninstall = @import("cli/uninstall.zig");
const update = @import("cli/update.zig");
const upgrade = @import("cli/upgrade.zig");
const uses = @import("cli/uses.zig");
const version_update = @import("cli/version_update.zig");
const which_cmd = @import("cli/which.zig");
const signals = @import("core/signals.zig");
const mirror_mod = @import("net/mirror.zig");
const color_mod = @import("ui/color.zig");
const output_mod = @import("ui/output.zig");
const progress_mod = @import("ui/progress.zig");
const notifier = @import("update/notifier.zig");
const version_mod = @import("version.zig");
const version = version_mod.value;

// Wrap the panic path so the cursor + autowrap state owned by
// MultiProgress / Spinner is restored before abort. Defers don't run
// on panic, so this is the only way to leave the terminal usable when
// install/migrate trips a safety check.
pub const panic = std.debug.FullPanic(maltPanic);

fn maltPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    progress_mod.restoreTerminal();
    if (@import("builtin").mode == .Debug) {
        std.debug.defaultPanic(msg, first_trace_addr);
    } else {
        // Release mirror of std.debug.simple_panic.call: emit the
        // message and trap, keeping debug.Dwarf out of the binary.
        const stderr_writer = &std.debug.lockStderr(&.{}).file_writer.interface;
        stderr_writer.writeAll(msg) catch {};
        @trap();
    }
}

// Gate `.debug` on the runtime --debug flag so release builds still
// surface std.log.debug diagnostics in bug reports.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = maltLogFn,
};

fn maltLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const output = @import("ui/output.zig");
    if (level == .debug and !output.isDebug()) return;
    std.log.defaultLog(level, scope, fmt, args);
}

// CLI command modules
const Command = enum {
    install,
    uninstall,
    upgrade,
    update,
    outdated,
    list,
    info,
    search,
    doctor,
    tap,
    untap,
    migrate,
    rollback,
    link,
    unlink,
    pin,
    unpin,
    run,
    version_cmd,
    completions,
    shellenv,
    backup,
    restore,
    purge,
    cleanup,
    services,
    bundle,
    uses,
    deps,
    which,
    help,
    version,
};

/// Aliases live beside their canonical tag so there's one source of
/// truth; `command_map` below is synthesised from this at comptime.
const command_names = [_]struct {
    tag: Command,
    names: []const []const u8,
}{
    .{ .tag = .install, .names = &.{"install"} },
    .{ .tag = .uninstall, .names = &.{ "uninstall", "remove" } },
    .{ .tag = .upgrade, .names = &.{"upgrade"} },
    .{ .tag = .update, .names = &.{"update"} },
    .{ .tag = .outdated, .names = &.{"outdated"} },
    .{ .tag = .list, .names = &.{ "list", "ls" } },
    .{ .tag = .info, .names = &.{"info"} },
    .{ .tag = .search, .names = &.{"search"} },
    .{ .tag = .doctor, .names = &.{"doctor"} },
    .{ .tag = .tap, .names = &.{"tap"} },
    .{ .tag = .untap, .names = &.{"untap"} },
    .{ .tag = .migrate, .names = &.{"migrate"} },
    .{ .tag = .rollback, .names = &.{"rollback"} },
    .{ .tag = .link, .names = &.{"link"} },
    .{ .tag = .unlink, .names = &.{"unlink"} },
    .{ .tag = .pin, .names = &.{"pin"} },
    .{ .tag = .unpin, .names = &.{"unpin"} },
    .{ .tag = .run, .names = &.{"run"} },
    .{ .tag = .version_cmd, .names = &.{"version"} },
    .{ .tag = .completions, .names = &.{"completions"} },
    .{ .tag = .shellenv, .names = &.{"shellenv"} },
    .{ .tag = .backup, .names = &.{"backup"} },
    .{ .tag = .restore, .names = &.{"restore"} },
    .{ .tag = .purge, .names = &.{"purge"} },
    .{ .tag = .cleanup, .names = &.{"cleanup"} },
    .{ .tag = .services, .names = &.{"services"} },
    .{ .tag = .bundle, .names = &.{"bundle"} },
    .{ .tag = .uses, .names = &.{"uses"} },
    .{ .tag = .deps, .names = &.{"deps"} },
    .{ .tag = .which, .names = &.{"which"} },
    .{ .tag = .help, .names = &.{ "help", "--help", "-h" } },
    .{ .tag = .version, .names = &.{"--version"} },
};

const command_map = blk: {
    @setEvalBranchQuota(10_000);
    var total: usize = 0;
    for (command_names) |entry| total += entry.names.len;
    var pairs: [total]struct { []const u8, Command } = undefined;
    var i: usize = 0;
    for (command_names) |entry| {
        for (entry.names) |name| {
            pairs[i] = .{ name, entry.tag };
            i += 1;
        }
    }
    break :blk std.StaticStringMap(Command).initComptime(pairs);
};

/// Set of process-wide flags consumed before subcommand dispatch.
/// StaticStringMap + exhaustive switch matches the install/upgrade
/// flag parsers and gives the compiler ownership of "every flag has a
/// handler" so adding a tag without wiring it fails to build.
const GlobalFlag = enum {
    verbose,
    debug,
    quiet,
    json,
    ndjson,
    dry_run,
};

const global_flag_map = std.StaticStringMap(GlobalFlag).initComptime(.{
    .{ "--verbose", .verbose },
    .{ "-v", .verbose },
    .{ "--debug", .debug },
    .{ "--quiet", .quiet },
    .{ "-q", .quiet },
    .{ "--json", .json },
    .{ "--output-format=ndjson", .ndjson },
    .{ "--dry-run", .dry_run },
});

/// Apply a global flag to the process-wide `output.*` state and report
/// whether it was consumed. Pulled out of `main` so the dispatch loop
/// stays a one-liner and the flag set is testable without spawning a
/// child process. Returns `false` for anything that should reach the
/// subcommand's argv.
pub fn applyGlobalFlag(arg: []const u8) bool {
    const output = @import("ui/output.zig");
    const flag = global_flag_map.get(arg) orelse return false;
    switch (flag) {
        .verbose => output.setVerbose(true),
        .debug => output.setDebug(true),
        .quiet => output.setQuiet(true),
        .json => output.setMode(.json),
        .ndjson => output.setNdjson(true),
        .dry_run => output.setDryRun(true),
    }
    return true;
}

test "applyGlobalFlag --output-format=ndjson toggles ndjson mode" {
    const output = @import("ui/output.zig");
    const prior = output.isNdjson();
    defer output.setNdjson(prior);
    output.setNdjson(false);

    try std.testing.expect(applyGlobalFlag("--output-format=ndjson"));
    try std.testing.expect(output.isNdjson());
}

test "applyGlobalFlag is orthogonal to --json" {
    const output = @import("ui/output.zig");
    const prior_ndjson = output.isNdjson();
    const prior_mode = output.isJson();
    defer {
        output.setNdjson(prior_ndjson);
        output.setMode(if (prior_mode) .json else .human);
    }
    output.setNdjson(false);
    output.setMode(.human);

    _ = applyGlobalFlag("--json");
    _ = applyGlobalFlag("--output-format=ndjson");
    try std.testing.expect(output.isJson());
    try std.testing.expect(output.isNdjson());
}

test "applyGlobalFlag returns false for unrecognised flags" {
    try std.testing.expect(!applyGlobalFlag("--cask"));
    try std.testing.expect(!applyGlobalFlag("--output-format=junk"));
    try std.testing.expect(!applyGlobalFlag("wget"));
}

test "dispatch accepts AppCtx and routes help without panic" {
    const ctx: AppCtx = .{ .io = std.Options.debug_io, .environ = .empty };
    try dispatch(std.testing.allocator, &ctx, .help, &.{});
}

test "command_map resolves cleanup to the cleanup tag" {
    // `mt cleanup` is the Homebrew-shaped alias for `mt purge --housekeeping`.
    // Pin the tag so a rename can't silently break the dispatch arm.
    try std.testing.expectEqual(@as(?Command, .cleanup), command_map.get("cleanup"));
}

test "dispatch clears stale interrupt under the test runner" {
    signals.setInterruptedForTest(true);
    defer signals.setInterruptedForTest(false);

    const ctx: AppCtx = .{ .io = std.Options.debug_io, .environ = .empty };
    try dispatch(std.testing.allocator, &ctx, .help, &.{});

    try std.testing.expect(!signals.isInterrupted());
}

test "dispatch preserves interrupt once the signal handler is installed" {
    signals.setSignalHandlerInstalledForTest(true);
    defer signals.setSignalHandlerInstalledForTest(false);
    signals.setInterruptedForTest(true);
    defer signals.setInterruptedForTest(false);

    const ctx: AppCtx = .{ .io = std.Options.debug_io, .environ = .empty };
    try dispatch(std.testing.allocator, &ctx, .help, &.{});

    try std.testing.expect(signals.isInterrupted());
}

test "applyGlobalFlag --output-format=ndjson does not flip --quiet" {
    // Compose with --quiet explicitly when needed; the streams are
    // already split (ndjson on stdout, human on stderr), so users
    // pipeline-redirect rather than have malt couple two concerns.
    const output = @import("ui/output.zig");
    const prior_ndjson = output.isNdjson();
    const prior_quiet = output.isQuiet();
    defer {
        output.setNdjson(prior_ndjson);
        output.setQuiet(prior_quiet);
    }
    output.setNdjson(false);
    output.setQuiet(false);

    _ = applyGlobalFlag("--output-format=ndjson");
    try std.testing.expect(output.isNdjson());
    try std.testing.expect(!output.isQuiet());
}

pub fn main(init: std.process.Init.Minimal) !void {
    // In debug builds, use GeneralPurposeAllocator as the backing
    // allocator for leak detection and use-after-free checks.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const backing: std.mem.Allocator = if (@import("builtin").mode == .Debug)
        gpa.allocator()
    else
        std.heap.page_allocator;
    defer if (@import("builtin").mode == .Debug) {
        if (gpa.deinit() == .leak) {
            std.log.err("memory leak detected", .{});
        }
    };

    // Register SIGINT handler so Ctrl-C sets the interrupt flag instead of
    // immediately killing the process. Install commands check the flag at
    // step boundaries and clean up before exiting.
    signals.installHandler();

    // Run terminal-background detection once, up front, before any
    // output.* call can trigger a lazy OSC 11 probe mid-stream (the
    // query write could otherwise land inside a progress-bar frame).
    _ = color_mod.background();
    _ = color_mod.truecolorSupported();

    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Single Threaded io for the whole process; outlives the ctx it backs.
    var threaded: std.Io.Threaded = .init(backing, .{ .environ = init.environ });
    defer threaded.deinit();

    // Resolve corporate-mirror overrides once, before any net/* call
    // site can read the env. A non-https override is fatal — refusing
    // it here keeps the redirect-downgrade guard in `net/client.zig`
    // load-bearing.
    const mirrors = mirror_mod.resolve(init.environ) catch |e| switch (e) {
        error.NonHttpsOverride => {
            const stderr = std.Io.File.stderr();
            stderr.writeStreamingAll(
                threaded.io(),
                "malt: MALT_API_DOMAIN / MALT_BOTTLE_DOMAIN (and HOMEBREW_* fallbacks) must use https://\n",
            ) catch {};
            std.process.exit(1);
        },
    };

    const ctx: AppCtx = .{
        .io = threaded.io(),
        .environ = init.environ,
        .stdout = std.Io.File.stdout(),
        .stderr = std.Io.File.stderr(),
        .mirrors = mirrors,
    };

    // Seed the ui package state once so output/progress/color stop
    // pulling io/environ/stdio from module-level globals.
    output_mod.setRuntime(ctx.io, ctx.environ, ctx.stdout, ctx.stderr);
    progress_mod.setRuntime(ctx.io, ctx.stderr);
    // `MALT_PROGRESS` and CI auto-detect resolve here; per-bar call sites
    // never re-read the env so install/upgrade/migrate stay in lockstep.
    progress_mod.setMode(progress_mod.resolveModeFromEnviron(ctx.environ));
    color_mod.setRuntime(ctx.io, ctx.environ);

    var args_it = try init.args.iterateAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.skip(); // skip argv0

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    while (args_it.next()) |arg| try args_list.append(allocator, arg);
    const args = args_list.items;

    if (args.len == 0) {
        printUsage(&ctx);
        return;
    }

    // Parse global flags before dispatch — strip them from the args
    // passed to subcommands so they don't need to parse them individually.
    var filtered: std.ArrayList([]const u8) = .empty;
    defer filtered.deinit(allocator);
    var cmd_str: []const u8 = "";
    var found_cmd = false;
    for (args) |arg| {
        if (!found_cmd and !std.mem.startsWith(u8, arg, "-")) {
            cmd_str = arg;
            found_cmd = true;
            continue;
        }
        // --help, -h, --version behave as commands when no other command has been seen yet.
        if (!found_cmd and (std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--version")))
        {
            cmd_str = arg;
            found_cmd = true;
            continue;
        }
        if (!applyGlobalFlag(arg)) try filtered.append(allocator, arg);
    }

    if (!found_cmd) {
        printUsage(&ctx);
        return;
    }
    const cmd_args = filtered.items;

    if (command_map.get(cmd_str)) |cmd| {
        // Any command can signal a user-facing failure by returning
        // `error.Aborted`; the message has already been emitted via
        // `output.err`, so we just exit non-zero without a stack trace.
        // Every other error still propagates and surfaces normally.
        dispatch(allocator, &ctx, cmd, cmd_args) catch |e| switch (e) {
            error.Aborted => std.process.exit(1),
            else => return e,
        };
        // Best-effort passive notice on successful subcommands. Owns its
        // own suppression list (CI, --quiet/--json/ndjson/--dry-run, env
        // opt-out, non-TTY, brew origin, version/help meta-commands).
        notifier.maybeNotify(&ctx, allocator, version, cmd_str);
    } else {
        // Unknown command — try transparent brew fallback
        try brewFallback(&ctx, args);
    }
}

fn dispatch(allocator: std.mem.Allocator, ctx: *const AppCtx, cmd: Command, cmd_args: []const []const u8) !void {
    // No SIGINT handler means we're under the test runner (or some other
    // non-`main` entry); clear any flag a prior test left behind so it
    // can't bleed into this dispatch.
    if (!signals.signalHandlerInstalled()) {
        signals.setInterruptedForTest(false);
    }
    switch (cmd) {
        .install => try install.execute(ctx, allocator, cmd_args),
        .uninstall => try uninstall.execute(ctx, allocator, cmd_args),
        .upgrade => try upgrade.execute(ctx, allocator, cmd_args),
        .update => try update.execute(ctx, allocator, cmd_args),
        .outdated => try outdated.execute(ctx, allocator, cmd_args),
        .list => try list.execute(ctx, cmd_args),
        .info => try info.execute(ctx, allocator, cmd_args),
        .search => try search.execute(ctx, allocator, cmd_args),
        .doctor => try doctor.execute(ctx, allocator, cmd_args),
        .tap => try tap.execute(ctx, allocator, cmd_args),
        .untap => try tap.executeUntap(ctx, allocator, cmd_args),
        .migrate => try migrate.execute(ctx, allocator, cmd_args),
        .rollback => try rollback.execute(ctx, allocator, cmd_args),
        .link => try link_cmd.executeLink(ctx, allocator, cmd_args),
        .unlink => try link_cmd.executeUnlink(ctx, allocator, cmd_args),
        .pin => try pin_cmd.execute(ctx, allocator, cmd_args),
        .unpin => try pin_cmd.executeUnpin(ctx, allocator, cmd_args),
        .run => try run_cmd.execute(ctx, allocator, cmd_args),
        .completions => try completions.execute(ctx, cmd_args),
        .shellenv => try shellenv.execute(ctx, allocator, cmd_args),
        .backup => try backup.execute(ctx, allocator, cmd_args),
        .restore => try restore.execute(ctx, allocator, cmd_args),
        .purge => try purge.execute(ctx, allocator, cmd_args),
        .cleanup => try purge.executeCleanup(ctx, allocator, cmd_args),
        .services => try services.execute(ctx, allocator, cmd_args),
        .bundle => try bundle.execute(ctx, allocator, cmd_args),
        .uses => try uses.execute(ctx, allocator, cmd_args),
        .deps => try deps_cmd.execute(ctx, allocator, cmd_args),
        .which => try which_cmd.execute(ctx, allocator, cmd_args),
        .version_cmd => {
            // "mt version" — check for "mt version update" subcommand
            if (cmd_args.len > 0 and std.mem.eql(u8, cmd_args[0], "update")) {
                try version_update.execute(ctx, allocator, cmd_args[1..]);
            } else {
                printVersion(ctx);
            }
        },
        .help => printUsage(ctx),
        .version => printVersion(ctx),
    }
}

fn printUsage(ctx: *const AppCtx) void {
    const usage =
        \\malt — a fast, drop-in Homebrew alternative for macOS.
        \\Warm installs in milliseconds. post_install scripts that actually run.
        \\
        \\Usage: malt <command> [options] [arguments]
        \\       mt <command> [options] [arguments]    (alias)
        \\
        \\Commands:
        \\  install       Install formulas, casks, or tap formulas
        \\  uninstall     Remove installed packages
        \\  upgrade       Upgrade installed packages
        \\  update        Refresh metadata cache
        \\  outdated      List packages with newer versions available
        \\  list          List installed packages
        \\  info          Show detailed package information
        \\  search        Search formulas and casks
        \\  uses          Show installed packages that depend on a formula
        \\  deps          Show what a formula depends on (forward of `uses`)
        \\  which         Resolve a prefix binary (or path) to its keg
        \\  doctor        System health check
        \\  tap/untap     Manage taps
        \\  migrate       Import existing Homebrew installation
        \\  rollback      Revert a package to its previous version
        \\  link          Create symlinks for an installed keg
        \\  unlink        Remove symlinks (keg stays installed)
        \\  pin           Protect an installed formula or cask from `upgrade`
        \\  unpin         Lift the pin so `upgrade` resumes touching it
        \\  run           Run a package binary without installing
        \\  completions   Generate shell completion scripts (bash, zsh, fish)
        \\  shellenv      Print PATH/MANPATH/HOMEBREW_PREFIX exports for shell init
        \\  backup        Dump installed packages to a restorable text file
        \\  restore       Reinstall every package listed in a backup file
        \\  purge         Housekeeping or full wipe (--store-orphans, --unused-deps,
        \\                --cache, --downloads, --stale-casks, --old-versions,
        \\                --housekeeping, --wipe)
        \\  cleanup       Shorthand for `purge --housekeeping`
        \\  services      Manage long-running launchd services (start/stop/status/logs)
        \\  bundle        Install or export a Brewfile/Maltfile.json set of packages
        \\  version       Show version (use 'version update' to self-update)
        \\
        \\Global flags:
        \\  --verbose, -v   Verbose output
        \\  --debug         Surface every DSL diagnostic (implies verbose);
        \\                  pair with issue reports for full context
        \\  --quiet, -q     Suppress non-error output
        \\  --json          JSON output (read commands)
        \\  --output-format=ndjson
        \\                  Stream one JSON event per state transition for
        \\                  install/upgrade/migrate (orthogonal to --json)
        \\  --dry-run       Preview without executing
        \\  --help, -h      Show help
        \\  --version       Show version
        \\
        \\Environment:
        \\  MALT_PREFIX       Override install prefix (default: /opt/malt)
        \\  MALT_CACHE        Override cache directory
        \\  NO_COLOR          Disable colored output
        \\  MALT_NO_EMOJI     Disable emoji in output
        \\  MALT_PROGRESS=tty|plain|none
        \\                    Choose how install/upgrade/migrate report progress;
        \\                    default auto-detects (CI=true flips to plain)
        \\  MALT_NO_VERSION_NOTIFIER=1
        \\                    Suppress the "newer malt available" stderr notice
        \\
    ;
    ctx.stdout.writeStreamingAll(ctx.io, usage) catch {};
}

fn printVersion(ctx: *const AppCtx) void {
    ctx.stdout.writeStreamingAll(ctx.io, "malt " ++ version ++ "\n") catch {};
}

fn brewFallback(ctx: *const AppCtx, args: []const []const u8) !void {
    // Try to find and exec the real brew binary
    const brew_paths = [_][]const u8{
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/home/linuxbrew/.linuxbrew/bin/brew",
    };

    for (brew_paths) |brew_path| {
        std.Io.Dir.accessAbsolute(ctx.io, brew_path, .{}) catch continue;

        // Build argv: [brew] ++ args
        var argv_buf: [128][]const u8 = undefined;
        argv_buf[0] = brew_path;
        const argc = @min(args.len, argv_buf.len - 1);
        for (args[0..argc], 1..) |arg, i| {
            argv_buf[i] = arg;
        }

        const argv = argv_buf[0 .. argc + 1];
        var spawned = std.process.spawn(ctx.io, .{ .argv = argv }) catch continue;
        const term = spawned.wait(ctx.io) catch continue;
        switch (term) {
            .exited => |code| {
                if (code != 0) return error.BrewFailed;
            },
            else => return error.BrewFailed,
        }
        return;
    }

    // brew not found
    if (args.len > 0) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "malt: '{s}' is not a malt command and brew was not found.\n", .{args[0]}) catch return;
        ctx.stderr.writeStreamingAll(ctx.io, msg) catch {};
    }
    ctx.stderr.writeStreamingAll(ctx.io, "Install Homebrew: https://brew.sh\n") catch {};
}
