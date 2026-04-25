//! malt — macOS package manager
//! CLI entry point and command dispatch for the `mt` binary.

const std = @import("std");
const fs_compat = @import("fs/compat.zig");
const io_mod = @import("ui/io.zig");
const color_mod = @import("ui/color.zig");

// Release uses simple_panic so debug.Dwarf stays unreachable (~30 KB smaller).
pub const panic = if (@import("builtin").mode == .Debug)
    std.debug.FullPanic(std.debug.defaultPanic)
else
    std.debug.simple_panic;

/// Global interrupt flag — set by SIGINT handler, checked at install step boundaries.
var interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn isInterrupted() bool {
    return interrupted.load(.acquire);
}

/// Test-only flag override — raising real SIGINT would race the test runner.
pub fn setInterruptedForTest(v: bool) void {
    interrupted.store(v, .release);
}

fn sigintHandler(_: std.c.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

// CLI command modules
const install = @import("cli/install.zig");
const uninstall = @import("cli/uninstall.zig");
const upgrade = @import("cli/upgrade.zig");
const update = @import("cli/update.zig");
const outdated = @import("cli/outdated.zig");
const list = @import("cli/list.zig");
const info = @import("cli/info.zig");
const search = @import("cli/search.zig");
const doctor = @import("cli/doctor.zig");
const tap = @import("cli/tap.zig");
const migrate = @import("cli/migrate.zig");
const rollback = @import("cli/rollback.zig");
const link_cmd = @import("cli/link.zig");
const pin_cmd = @import("cli/pin.zig");
const run_cmd = @import("cli/run.zig");
const version_update = @import("cli/version_update.zig");
const completions = @import("cli/completions.zig");
const shellenv = @import("cli/shellenv.zig");
const backup = @import("cli/backup.zig");
const restore = @import("cli/restore.zig");
const purge = @import("cli/purge.zig");
const services = @import("cli/services.zig");
const bundle = @import("cli/bundle.zig");
const uses = @import("cli/uses.zig");
const which_cmd = @import("cli/which.zig");

const version_mod = @import("version.zig");
const version = version_mod.value;

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
    services,
    bundle,
    uses,
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
    .{ .tag = .services, .names = &.{"services"} },
    .{ .tag = .bundle, .names = &.{"bundle"} },
    .{ .tag = .uses, .names = &.{"uses"} },
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

    // Register SIGINT handler so Ctrl-C sets interrupted instead of
    // immediately killing the process. Install commands check the flag at
    // step boundaries and clean up before exiting.
    const act = std.posix.Sigaction{
        .handler = .{ .handler = &sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    // Run terminal-background detection once, up front, before any
    // output.* call can trigger a lazy OSC 11 probe mid-stream (the
    // query write could otherwise land inside a progress-bar frame).
    _ = color_mod.background();
    _ = color_mod.truecolorSupported();

    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_it = try init.args.iterateAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.skip(); // skip argv0

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    while (args_it.next()) |arg| try args_list.append(allocator, arg);
    const args = args_list.items;

    if (args.len == 0) {
        printUsage();
        return;
    }

    // Parse global flags before dispatch — strip them from the args
    // passed to subcommands so they don't need to parse them individually.
    const output = @import("ui/output.zig");
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
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            output.setVerbose(true);
        } else if (std.mem.eql(u8, arg, "--debug")) {
            output.setDebug(true);
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            output.setQuiet(true);
        } else if (std.mem.eql(u8, arg, "--json")) {
            output.setMode(.json);
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            output.setDryRun(true);
        } else {
            try filtered.append(allocator, arg);
        }
    }

    if (!found_cmd) {
        printUsage();
        return;
    }
    const cmd_args = filtered.items;

    if (command_map.get(cmd_str)) |cmd| {
        // Any command can signal a user-facing failure by returning
        // `error.Aborted`; the message has already been emitted via
        // `output.err`, so we just exit non-zero without a stack trace.
        // Every other error still propagates and surfaces normally.
        dispatch(allocator, cmd, cmd_args) catch |e| switch (e) {
            error.Aborted => std.process.exit(1),
            else => return e,
        };
    } else {
        // Unknown command — try transparent brew fallback
        try brewFallback(allocator, args);
    }
}

fn dispatch(allocator: std.mem.Allocator, cmd: Command, cmd_args: []const []const u8) !void {
    switch (cmd) {
        .install => try install.execute(allocator, cmd_args),
        .uninstall => try uninstall.execute(allocator, cmd_args),
        .upgrade => try upgrade.execute(allocator, cmd_args),
        .update => try update.execute(allocator, cmd_args),
        .outdated => try outdated.execute(allocator, cmd_args),
        .list => try list.execute(allocator, cmd_args),
        .info => try info.execute(allocator, cmd_args),
        .search => try search.execute(allocator, cmd_args),
        .doctor => try doctor.execute(allocator, cmd_args),
        .tap => try tap.execute(allocator, cmd_args),
        .untap => try tap.executeUntap(allocator, cmd_args),
        .migrate => try migrate.execute(allocator, cmd_args),
        .rollback => try rollback.execute(allocator, cmd_args),
        .link => try link_cmd.executeLink(allocator, cmd_args),
        .unlink => try link_cmd.executeUnlink(allocator, cmd_args),
        .pin => try pin_cmd.execute(allocator, cmd_args),
        .unpin => try pin_cmd.executeUnpin(allocator, cmd_args),
        .run => try run_cmd.execute(allocator, cmd_args),
        .completions => try completions.execute(allocator, cmd_args),
        .shellenv => try shellenv.execute(allocator, cmd_args),
        .backup => try backup.execute(allocator, cmd_args),
        .restore => try restore.execute(allocator, cmd_args),
        .purge => try purge.execute(allocator, cmd_args),
        .services => try services.execute(allocator, cmd_args),
        .bundle => try bundle.execute(allocator, cmd_args),
        .uses => try uses.execute(allocator, cmd_args),
        .which => try which_cmd.execute(allocator, cmd_args),
        .version_cmd => {
            // "mt version" — check for "mt version update" subcommand
            if (cmd_args.len > 0 and std.mem.eql(u8, cmd_args[0], "update")) {
                try version_update.execute(allocator, cmd_args[1..]);
            } else {
                printVersion();
            }
        },
        .help => printUsage(),
        .version => printVersion(),
    }
}

fn printUsage() void {
    const usage =
        \\malt — a fast macOS package manager (Homebrew-compatible)
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
        \\  which         Resolve a prefix binary (or path) to its keg
        \\  doctor        System health check
        \\  tap/untap     Manage taps
        \\  migrate       Import existing Homebrew installation
        \\  rollback      Revert a package to its previous version
        \\  link          Create symlinks for an installed keg
        \\  unlink        Remove symlinks (keg stays installed)
        \\  pin           Protect an installed keg from `upgrade`
        \\  unpin         Lift the pin so `upgrade` resumes touching it
        \\  run           Run a package binary without installing
        \\  completions   Generate shell completion scripts (bash, zsh, fish)
        \\  shellenv      Print PATH/MANPATH/HOMEBREW_PREFIX exports for shell init
        \\  backup        Dump installed packages to a restorable text file
        \\  restore       Reinstall every package listed in a backup file
        \\  purge         Housekeeping or full wipe (--store-orphans, --unused-deps,
        \\                --cache, --downloads, --stale-casks, --old-versions,
        \\                --housekeeping, --wipe)
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
        \\  --dry-run       Preview without executing
        \\  --help, -h      Show help
        \\  --version       Show version
        \\
        \\Environment:
        \\  MALT_PREFIX       Override install prefix (default: /opt/malt)
        \\  MALT_CACHE        Override cache directory
        \\  NO_COLOR          Disable colored output
        \\  MALT_NO_EMOJI     Disable emoji in output
        \\
    ;
    io_mod.stdoutWriteAll(usage);
}

fn printVersion() void {
    io_mod.stdoutWriteAll("malt " ++ version ++ "\n");
}

fn brewFallback(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Try to find and exec the real brew binary
    const brew_paths = [_][]const u8{
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/home/linuxbrew/.linuxbrew/bin/brew",
    };

    for (brew_paths) |brew_path| {
        fs_compat.accessAbsolute(brew_path, .{}) catch continue;

        // Build argv: [brew] ++ args
        var argv_buf: [128][]const u8 = undefined;
        argv_buf[0] = brew_path;
        const argc = @min(args.len, argv_buf.len - 1);
        for (args[0..argc], 1..) |arg, i| {
            argv_buf[i] = arg;
        }

        var child = fs_compat.Child.init(argv_buf[0 .. argc + 1], allocator);
        child.spawn() catch continue;
        const term = child.wait() catch continue;
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
        io_mod.stderrWriteAll(msg);
    }
    io_mod.stderrWriteAll("Install Homebrew: https://brew.sh\n");
}
