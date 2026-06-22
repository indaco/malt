//! malt — macOS package manager
//! CLI entry point and command dispatch for the `mt` binary.

const std = @import("std");

const AppCtx = @import("app_ctx.zig").AppCtx;
const backup = @import("cli/backup.zig");
const bundle = @import("cli/bundle.zig");
const completions = @import("cli/completions.zig");
const deps_cmd = @import("cli/deps.zig");
const cli_help = @import("cli/help.zig");
const doctor = @import("cli/doctor.zig");
const info = @import("cli/info.zig");
const install = @import("cli/install.zig");
const link_cmd = @import("cli/link.zig");
const list = @import("cli/list.zig");
const migrate = @import("cli/migrate.zig");
const outdated = @import("cli/outdated.zig");
const pin_cmd = @import("cli/pin.zig");
const purge = @import("cli/purge.zig");
const reinstall = @import("cli/reinstall.zig");
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
const offline_mod = @import("net/offline.zig");
const color_mod = @import("ui/color.zig");
const custom_theme = @import("ui/custom_theme.zig");
const theme_file = @import("fs/theme_file.zig");
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
    reinstall,
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
    version,
    completions,
    shellenv,
    backup,
    restore,
    purge,
    cleanup,
    services,
    tui,
    bundle,
    uses,
    deps,
    which,
    help,
    version_flag,
};

/// Aliases live beside their canonical tag so there's one source of
/// truth; `command_map` below is synthesised from this at comptime.
const command_names = [_]struct {
    tag: Command,
    names: []const []const u8,
}{
    .{ .tag = .install, .names = &.{"install"} },
    .{ .tag = .reinstall, .names = &.{"reinstall"} },
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
    .{ .tag = .version, .names = &.{"version"} },
    .{ .tag = .completions, .names = &.{"completions"} },
    .{ .tag = .shellenv, .names = &.{"shellenv"} },
    .{ .tag = .backup, .names = &.{"backup"} },
    .{ .tag = .restore, .names = &.{"restore"} },
    .{ .tag = .purge, .names = &.{"purge"} },
    .{ .tag = .cleanup, .names = &.{"cleanup"} },
    .{ .tag = .services, .names = &.{"services"} },
    .{ .tag = .tui, .names = &.{"tui"} },
    .{ .tag = .bundle, .names = &.{"bundle"} },
    .{ .tag = .uses, .names = &.{"uses"} },
    .{ .tag = .deps, .names = &.{"deps"} },
    .{ .tag = .which, .names = &.{"which"} },
    .{ .tag = .help, .names = &.{ "help", "--help", "-h" } },
    .{ .tag = .version_flag, .names = &.{"--version"} },
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

test "applyGlobalFlag does not consume --offline (handled inline by main)" {
    // `--offline` lives on ctx, not module state; if applyGlobalFlag
    // ever started consuming it the inline branch in `main` would be
    // dead code and ctx.offline would silently stop tracking the flag.
    try std.testing.expect(!applyGlobalFlag("--offline"));
}

test "command_map resolves cleanup to the cleanup tag" {
    // `mt cleanup` is the Homebrew-shaped alias for `mt purge --housekeeping`.
    // Pin the tag so a rename can't silently break the dispatch arm.
    try std.testing.expectEqual(@as(?Command, .cleanup), command_map.get("cleanup"));
}

test "command_map resolves reinstall to the reinstall tag" {
    // `mt reinstall` is the discoverable verb for `mt install --force`.
    // Pin the tag so a rename can't silently break the dispatch arm.
    try std.testing.expectEqual(@as(?Command, .reinstall), command_map.get("reinstall"));
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

test "formatBrewFallbackNotice names the input and signals the brew handoff" {
    var buf: [256]u8 = undefined;
    const notice = try formatBrewFallbackNotice(&buf, "pfoo");
    try std.testing.expect(std.mem.indexOf(u8, notice, "'pfoo'") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "is not a malt command") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "brew") != null);
}

test "formatSlugHint for 2-segment slug names both install and tap verbs" {
    var buf: [256]u8 = undefined;
    const hint = try formatSlugHint(&buf, .tap_slug_2, "aeroxy/ast-outline");
    try std.testing.expect(std.mem.indexOf(u8, hint, "mt install aeroxy/ast-outline/<formula>") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "mt tap aeroxy/ast-outline") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "is not a malt command") != null);
}

test "formatSlugHint for 3-segment slug names install without <formula> placeholder" {
    var buf: [256]u8 = undefined;
    const hint = try formatSlugHint(&buf, .tap_slug_3, "a/b/c");
    try std.testing.expect(std.mem.indexOf(u8, hint, "mt install a/b/c") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "<formula>") == null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "is not a malt command") != null);
}

test "classifyFirstPositional routes slug-shaped, path, and verb-shaped inputs" {
    try std.testing.expectEqual(FirstPositional.tap_slug_2, classifyFirstPositional("aeroxy/ast-outline"));
    try std.testing.expectEqual(FirstPositional.tap_slug_3, classifyFirstPositional("aeroxy/ast-outline/ast-outline"));
    try std.testing.expectEqual(FirstPositional.brew_fallback, classifyFirstPositional("./hello.rb"));
    try std.testing.expectEqual(FirstPositional.brew_fallback, classifyFirstPositional("/tmp/x.rb"));
    try std.testing.expectEqual(FirstPositional.brew_fallback, classifyFirstPositional("~/foo.rb"));
    try std.testing.expectEqual(FirstPositional.brew_fallback, classifyFirstPositional("isntall"));
    try std.testing.expectEqual(FirstPositional.brew_fallback, classifyFirstPositional("cellar"));
    // Edge cases: empty argv slot and 4+ segment paths never look like a tap slug.
    try std.testing.expectEqual(FirstPositional.brew_fallback, classifyFirstPositional(""));
    try std.testing.expectEqual(FirstPositional.brew_fallback, classifyFirstPositional("a/b/c/d"));
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

    // `MALT_OFFLINE` is resolved once at boot; `--offline` may flip it
    // on later in the dispatch loop (parsed below alongside other globals).
    var ctx: AppCtx = .{
        .io = threaded.io(),
        .environ = init.environ,
        .stdout = std.Io.File.stdout(),
        .stderr = std.Io.File.stderr(),
        .mirrors = mirrors,
        .offline = offline_mod.resolveFromEnv(init.environ),
    };

    // Seed the ui package state once so output/progress/color stop
    // pulling io/environ/stdio from module-level globals.
    output_mod.setRuntime(ctx.io, ctx.environ, ctx.stdout, ctx.stderr);
    progress_mod.setRuntime(ctx.io, ctx.stderr);
    // `MALT_PROGRESS` and CI auto-detect resolve here; per-bar call sites
    // never re-read the env so install/upgrade/migrate stay in lockstep.
    progress_mod.setMode(progress_mod.resolveModeFromEnviron(ctx.environ));
    color_mod.setRuntime(ctx.io, ctx.environ);

    // Load any user theme file once, before colour state is read. The file is
    // read through the hardened fs path (validated, non-symlink, size-capped) and
    // a malformed file is rejected whole — built-ins kept, one notice, no crash.
    // Off the install/upgrade hot path; a missing file is a single failed stat.
    {
        var theme_buf: [custom_theme.max_file_bytes]u8 = undefined;
        const bytes = theme_file.read(ctx.io, ctx.environ, &theme_buf);
        if (color_mod.installCustomThemes(allocator, bytes) == .rejected)
            output_mod.notice("ignoring malformed themes file; using built-in themes", .{});
    }

    // Resolve the env-derived colour state once, now that the real environ is
    // seeded — before any output (or TUI frame) reads it. Doing the OSC 11
    // background probe up front keeps the query write out of a progress frame;
    // resolving MALT_THEME / COLORTERM here is what lets the TUI theme apply.
    _ = color_mod.background();
    _ = color_mod.truecolorSupported();
    _ = color_mod.theme();

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
        if (std.mem.eql(u8, arg, "--offline")) {
            // `--offline` lives on ctx (not module state) so subcommands
            // read it via the typed pointer rather than a hidden global.
            ctx.offline = true;
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
        // install / reinstall / upgrade additionally surface typed
        // `InstallError` values (kept that way for testability) that have
        // likewise already been printed — treat them the same so a clean
        // refusal isn't followed by a raw `error: <Enum>` line. Scoped to
        // that family because Zig error values are global by name: a
        // same-named error (e.g. NetworkError) from another command must
        // still surface loudly. Truly unexpected errors propagate too.
        const install_family = cmd == .install or cmd == .reinstall or cmd == .upgrade;
        dispatch(allocator, &ctx, cmd, cmd_args) catch |e| switch (e) {
            error.Aborted => std.process.exit(1),
            else => if (install_family and install.isReportedInstallError(e)) std.process.exit(1) else return e,
        };
        // Best-effort passive notice on successful subcommands. Owns its
        // own suppression list (CI, --quiet/--json/ndjson/--dry-run, env
        // opt-out, non-TTY, brew origin, version/help meta-commands).
        notifier.maybeNotify(&ctx, allocator, version, cmd_str);
    } else {
        // Unknown command — slug-shaped inputs (`user/repo`,
        // `user/repo/formula`) exit with a malt-native verb hint;
        // anything else gets a one-line "not a malt command" notice
        // and then forwards to brew so `mt isntall jq` or `mt cellar`
        // still reach the real binary.
        const kind = classifyFirstPositional(cmd_str);
        switch (kind) {
            .tap_slug_2, .tap_slug_3 => {
                var buf: [1024]u8 = undefined;
                // 1024 covers any realistic slug; bufPrint can only fail
                // on overflow, and the slug came from argv.
                const hint = formatSlugHint(&buf, kind, cmd_str) catch unreachable;
                output_mod.err("{s}", .{hint});
                std.process.exit(1);
            },
            .brew_fallback => try brewFallback(&ctx, cmd_str, args),
        }
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
        .reinstall => try reinstall.execute(ctx, allocator, cmd_args),
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
        // Lazy: the TUI leaf is referenced only here, so non-`tui` commands pay
        // no cold-start cost. `--help` is handled in the bridge because the leaf
        // can't reach `cli/help`. Reads parse `mt … --json`; writes re-exec `mt`.
        .tui => {
            if (cli_help.showIfRequested(ctx, cmd_args, "tui")) return;
            // Resolve this binary's path so the TUI re-execs the *same* `mt` for
            // delegated mutations; fall back to `mt` (PATH) if it can't be read.
            var self_buf: [std.fs.max_path_bytes]u8 = undefined;
            const mt_path = if (std.process.executablePath(ctx.io, &self_buf)) |n| self_buf[0..n] else |_| "mt";
            try @import("tui/app.zig").run(ctx.io, allocator, ctx.stderr, ctx.environ, mt_path, version);
        },
        .bundle => try bundle.execute(ctx, allocator, cmd_args),
        .uses => try uses.execute(ctx, allocator, cmd_args),
        .deps => try deps_cmd.execute(ctx, allocator, cmd_args),
        .which => try which_cmd.execute(ctx, allocator, cmd_args),
        .version => {
            // "mt version" — check for "mt version update" subcommand
            if (cmd_args.len > 0 and std.mem.eql(u8, cmd_args[0], "update")) {
                try version_update.execute(ctx, allocator, cmd_args[1..]);
            } else {
                printVersion(ctx);
            }
        },
        .help => printUsage(ctx),
        .version_flag => printVersion(ctx),
    }
}

fn printUsage(ctx: *const AppCtx) void {
    const usage =
        \\malt — Homebrew's whole ecosystem, none of its weight.
        \\Reuses every formula, bottle, and Brewfile; runs post_install natively.
        \\Themeable TUI and CLI.
        \\
        \\Usage: malt <command> [options] [arguments]
        \\       mt <command> [options] [arguments]    (alias)
        \\
        \\Commands:
        \\  install       Install formulas, casks, or tap formulas
        \\  reinstall     Wipe and re-materialise an installed package
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
        \\  tui           Interactive dashboard (search, installed, outdated, services, doctor)
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
        \\  --offline       Serve every fetch from the snapshot cache; fail
        \\                  fast with OfflineRequired on a miss
        \\  --help, -h      Show help
        \\  --version       Show version
        \\
        \\Environment:
        \\  MALT_PREFIX       Override install prefix (default: /opt/malt)
        \\  MALT_CACHE        Override cache directory (default: {prefix}/cache)
        \\  NO_COLOR          Disable colored output
        \\  MALT_NO_EMOJI     Disable emoji in output
        \\  MALT_NO_VERSION_NOTIFIER=1
        \\                    Suppress the "newer malt available" stderr notice
        \\  MALT_PROGRESS=tty|plain|none
        \\                    Choose how install/upgrade/migrate report progress;
        \\                    default auto-detects (CI=true flips to plain)
        \\  MALT_THEME        Colour theme for CLI and tui: light/dark/auto, or a
        \\                    named palette (dracula, nord, gruvbox-dark, ...);
        \\                    default auto
        \\  MALT_THEMES_FILE  Path to a JSON file of custom themes
        \\                    (default: {prefix}/etc/malt/themes.json)
        \\  HOMEBREW_GITHUB_API_TOKEN
        \\                    GitHub token for higher API rate limits
        \\  MALT_GITHUB_TOKEN GitHub token sent as Bearer on tap commit lookups
        \\  MALT_GITLAB_TOKEN GitLab token (PRIVATE-TOKEN) for GitLab-hosted taps
        \\  MALT_GITEA_TOKEN  Codeberg/Forgejo/Gitea token for those taps
        \\  MALT_HTTP_IDLE_TIMEOUT_SECS
        \\                    HTTP idle read timeout, seconds (clamped to [5, 600])
        \\  MALT_API_DOMAIN   Override metadata API base URL (HTTPS only)
        \\  MALT_BOTTLE_DOMAIN
        \\                    Override bottle registry base URL (HTTPS only)
        \\  MALT_OFFLINE=1    Same as --offline: every fetch must serve from
        \\                    the snapshot cache
        \\  MALT_MIGRATE_PARALLEL_WORKERS
        \\                    Worker count for migrate --parallel (clamped to [1, 32])
        \\  MALT_OUTDATED_MAX_AGE
        \\                    TTL in minutes for the outdated.json snapshot
        \\  MALT_ALLOW_RAW_POST_INSTALL
        \\                    Disable the terminal-escape filter on ruby
        \\                    post_install output
        \\  MALT_ALLOW_UNVERIFIED=1
        \\                    Skip signature + checksum verify for version update
        \\                    --no-verify (not recommended)
        \\
    ;
    ctx.stdout.writeStreamingAll(ctx.io, usage) catch {};
}

fn printVersion(ctx: *const AppCtx) void {
    ctx.stdout.writeStreamingAll(ctx.io, "malt " ++ version ++ "\n") catch {};
}

/// Steers slug-shaped typos to a malt-native hint while keeping every
/// other unknown command on the brew fallback path.
const FirstPositional = union(enum) {
    tap_slug_2,
    tap_slug_3,
    brew_fallback,
};

fn classifyFirstPositional(arg: []const u8) FirstPositional {
    if (arg.len == 0) return .brew_fallback;
    // Path-shaped inputs may still be valid for brew (e.g. install from
    // a local .rb), so let the fallback see them.
    if (std.mem.startsWith(u8, arg, "./") or
        std.mem.startsWith(u8, arg, "/") or
        std.mem.startsWith(u8, arg, "~/")) return .brew_fallback;
    const slashes = std.mem.count(u8, arg, "/");
    return switch (slashes) {
        1 => .tap_slug_2,
        2 => .tap_slug_3,
        else => .brew_fallback,
    };
}

fn formatBrewFallbackNotice(buf: []u8, cmd: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "'{s}' is not a malt command — malt forwards unknown commands to brew. Output below is brew's.",
        .{cmd},
    );
}

fn formatSlugHint(buf: []u8, kind: FirstPositional, slug: []const u8) ![]const u8 {
    return switch (kind) {
        .tap_slug_2 => std.fmt.bufPrint(
            buf,
            "'{s}' is not a malt command. Did you mean `mt install {s}/<formula>` or `mt tap {s}`?",
            .{ slug, slug, slug },
        ),
        .tap_slug_3 => std.fmt.bufPrint(
            buf,
            "'{s}' is not a malt command. Did you mean `mt install {s}`?",
            .{ slug, slug },
        ),
        .brew_fallback => error.NotASlugTypo,
    };
}

fn brewFallback(ctx: *const AppCtx, cmd: []const u8, args: []const []const u8) !void {
    // Try to find and exec the real brew binary
    const brew_paths = [_][]const u8{
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/home/linuxbrew/.linuxbrew/bin/brew",
    };

    for (brew_paths) |brew_path| {
        std.Io.Dir.accessAbsolute(ctx.io, brew_path, .{}) catch continue;

        // Announce the handoff once we know brew is reachable so the
        // user sees a malt-native context line before brew's own
        // output. Passive notice — brew owns success/failure reporting.
        var notice_buf: [1024]u8 = undefined;
        // Cmd came from argv; 1024 is generous, so bufPrint cannot overflow.
        const notice = formatBrewFallbackNotice(&notice_buf, cmd) catch unreachable;
        output_mod.notice("{s}", .{notice});
        // Visual gap so brew's output reads as a distinct block.
        ctx.stderr.writeStreamingAll(ctx.io, "\n") catch {};

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
