//! malt — macOS package manager
//! CLI entry point and command dispatch for the `mt` binary.

const std = @import("std");

// CLI command modules
const install = @import("cli/install.zig");
const uninstall = @import("cli/uninstall.zig");
const upgrade = @import("cli/upgrade.zig");
const update = @import("cli/update.zig");
const outdated = @import("cli/outdated.zig");
const list = @import("cli/list.zig");
const info = @import("cli/info.zig");
const search = @import("cli/search.zig");
const cleanup = @import("cli/cleanup.zig");
const doctor = @import("cli/doctor.zig");
const tap = @import("cli/tap.zig");
const gc = @import("cli/gc.zig");
const migrate = @import("cli/migrate.zig");
const autoremove = @import("cli/autoremove.zig");
const rollback = @import("cli/rollback.zig");
const run_cmd = @import("cli/run.zig");
const version_update = @import("cli/version_update.zig");

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
    cleanup,
    doctor,
    tap,
    untap,
    gc,
    migrate,
    autoremove,
    rollback,
    run,
    version_cmd,
    help,
    version,
};

const command_map = std.StaticStringMap(Command).initComptime(.{
    .{ "install", .install },
    .{ "uninstall", .uninstall },
    .{ "remove", .uninstall },
    .{ "upgrade", .upgrade },
    .{ "update", .update },
    .{ "outdated", .outdated },
    .{ "list", .list },
    .{ "ls", .list },
    .{ "info", .info },
    .{ "search", .search },
    .{ "cleanup", .cleanup },
    .{ "doctor", .doctor },
    .{ "tap", .tap },
    .{ "untap", .untap },
    .{ "gc", .gc },
    .{ "migrate", .migrate },
    .{ "autoremove", .autoremove },
    .{ "rollback", .rollback },
    .{ "run", .run },
    .{ "help", .help },
    .{ "--help", .help },
    .{ "-h", .help },
    .{ "version", .version_cmd },
    .{ "--version", .version },
});

pub fn main() !void {
    // In debug builds, use GeneralPurposeAllocator as the backing
    // allocator for leak detection and use-after-free checks.
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const backing: std.mem.Allocator = if (@import("builtin").mode == .Debug)
        gpa.allocator()
    else
        std.heap.page_allocator;
    defer if (@import("builtin").mode == .Debug) {
        if (gpa.deinit() == .leak) {
            std.log.err("memory leak detected", .{});
        }
    };

    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    if (args.len < 2) {
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
    for (args[1..]) |arg| {
        if (!found_cmd and !std.mem.startsWith(u8, arg, "-")) {
            cmd_str = arg;
            found_cmd = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            output.setVerbose(true);
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            output.setQuiet(true);
        } else if (std.mem.eql(u8, arg, "--json")) {
            output.setMode(.json);
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            output.setDryRun(true);
        } else {
            filtered.append(allocator, arg) catch {};
        }
    }

    if (!found_cmd) {
        printUsage();
        return;
    }
    const cmd_args = filtered.items;

    if (command_map.get(cmd_str)) |cmd| {
        switch (cmd) {
            .install => try install.execute(allocator, cmd_args),
            .uninstall => try uninstall.execute(allocator, cmd_args),
            .upgrade => try upgrade.execute(allocator, cmd_args),
            .update => try update.execute(allocator, cmd_args),
            .outdated => try outdated.execute(allocator, cmd_args),
            .list => try list.execute(allocator, cmd_args),
            .info => try info.execute(allocator, cmd_args),
            .search => try search.execute(allocator, cmd_args),
            .cleanup => try cleanup.execute(allocator, cmd_args),
            .doctor => try doctor.execute(allocator, cmd_args),
            .tap, .untap => try tap.execute(allocator, cmd_args),
            .gc => try gc.execute(allocator, cmd_args),
            .migrate => try migrate.execute(allocator, cmd_args),
            .autoremove => try autoremove.execute(allocator, cmd_args),
            .rollback => try rollback.execute(allocator, cmd_args),
            .run => try run_cmd.execute(allocator, cmd_args),
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
    } else {
        // Unknown command — try transparent brew fallback
        try brewFallback(allocator, args[1..]);
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
        \\  cleanup       Remove old versions and prune caches
        \\  doctor        System health check
        \\  tap/untap     Manage taps
        \\  gc            Garbage collect unreferenced store entries
        \\  migrate       Import existing Homebrew installation
        \\  autoremove    Remove orphaned dependencies
        \\  rollback      Revert a package to its previous version
        \\  run           Run a package binary without installing
        \\  version       Show version (use 'version update' to self-update)
        \\
        \\Global flags:
        \\  --verbose, -v   Verbose output
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
    std.fs.File.stdout().writeAll(usage) catch {};
}

fn printVersion() void {
    std.fs.File.stdout().writeAll("malt " ++ version ++ "\n") catch {};
}

fn brewFallback(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Try to find and exec the real brew binary
    const brew_paths = [_][]const u8{
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/home/linuxbrew/.linuxbrew/bin/brew",
    };

    for (brew_paths) |brew_path| {
        std.fs.accessAbsolute(brew_path, .{}) catch continue;

        // Build argv: [brew] ++ args
        var argv_buf: [128][]const u8 = undefined;
        argv_buf[0] = brew_path;
        const argc = @min(args.len, argv_buf.len - 1);
        for (args[0..argc], 1..) |arg, i| {
            argv_buf[i] = arg;
        }

        var child = std.process.Child.init(argv_buf[0 .. argc + 1], allocator);
        child.spawn() catch continue;
        const term = child.wait() catch continue;
        switch (term) {
            .Exited => |code| {
                if (code != 0) return error.BrewFailed;
            },
            else => return error.BrewFailed,
        }
        return;
    }

    // brew not found
    const stderr = std.fs.File.stderr();
    if (args.len > 0) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "malt: '{s}' is not a malt command and brew was not found.\n", .{args[0]}) catch return;
        stderr.writeAll(msg) catch {};
    }
    stderr.writeAll("Install Homebrew: https://brew.sh\n") catch {};
}
