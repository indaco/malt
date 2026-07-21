//! malt — completions command tests
//! Exercises shell parsing and verifies that generated scripts reference
//! every subcommand exposed by the CLI. The execute() function writes to
//! stdout and calls std.process.exit on error, so tests target the pure
//! helpers (parseShell, scriptFor) and the script constants instead.

const std = @import("std");
const testing = std.testing;

const completions = @import("malt").completions;

test "parseShell recognises the three supported shells" {
    try testing.expectEqual(completions.Shell.bash, completions.parseShell("bash").?);
    try testing.expectEqual(completions.Shell.zsh, completions.parseShell("zsh").?);
    try testing.expectEqual(completions.Shell.fish, completions.parseShell("fish").?);
}

test "parseShell returns null for unknown shells" {
    // malt is macOS-only, so the realistic miss-cases are other POSIX shells
    // that ship on macOS (or an empty / wrong-case input), not PowerShell.
    try testing.expect(completions.parseShell("tcsh") == null);
    try testing.expect(completions.parseShell("ksh") == null);
    try testing.expect(completions.parseShell("sh") == null);
    try testing.expect(completions.parseShell("Bash") == null); // case-sensitive
    try testing.expect(completions.parseShell("") == null);
}

test "scriptFor routes each shell to a non-empty script" {
    try testing.expect(completions.scriptFor(.bash).len > 0);
    try testing.expect(completions.scriptFor(.zsh).len > 0);
    try testing.expect(completions.scriptFor(.fish).len > 0);
    // Routing must be distinct — each variant returns a different script.
    try testing.expect(!std.mem.eql(u8, completions.scriptFor(.bash), completions.scriptFor(.zsh)));
    try testing.expect(!std.mem.eql(u8, completions.scriptFor(.bash), completions.scriptFor(.fish)));
    try testing.expect(!std.mem.eql(u8, completions.scriptFor(.zsh), completions.scriptFor(.fish)));
}

const all_commands = [_][]const u8{
    "install",  "reinstall", "uninstall",   "remove",
    "upgrade",  "update",    "outdated",    "list",
    "ls",       "info",      "search",      "doctor",
    "tap",      "untap",     "migrate",     "rollback",
    "link",     "unlink",    "pin",         "unpin",
    "run",      "version",   "completions", "shellenv",
    "backup",   "restore",   "purge",       "cleanup",
    "services", "bundle",    "which",       "deps",
    "tui",
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected script to contain '{s}'\n", .{needle});
        return error.MissingSubstring;
    }
}

test "bash script covers every subcommand and both binary names" {
    const script = completions.bash_script;
    for (all_commands) |cmd| try expectContains(script, cmd);
    // Binary registrations.
    try expectContains(script, "complete -F _malt_complete malt");
    try expectContains(script, "complete -F _malt_complete mt");
    // Install hint.
    try expectContains(script, "eval \"$(malt completions bash)\"");
}

test "zsh script covers every subcommand and registers compdef" {
    const script = completions.zsh_script;
    try expectContains(script, "#compdef malt mt");
    try expectContains(script, "_malt()");
    try expectContains(script, "compdef _malt malt mt");
    for (all_commands) |cmd| try expectContains(script, cmd);
    // Install hint.
    try expectContains(script, "eval \"$(malt completions zsh)\"");
}

test "fish script covers every subcommand and both binary names" {
    const script = completions.fish_script;
    try expectContains(script, "for __malt_bin in malt mt");
    try expectContains(script, "__malt_needs_command");
    try expectContains(script, "__malt_using_command");
    for (all_commands) |cmd| try expectContains(script, cmd);
    // Install hint.
    try expectContains(script, "malt completions fish | source");
}

test "all scripts complete the three shells for the completions subcommand" {
    for ([_][]const u8{
        completions.bash_script,
        completions.zsh_script,
        completions.fish_script,
    }) |script| {
        try expectContains(script, "bash");
        try expectContains(script, "zsh");
        try expectContains(script, "fish");
    }
}

test "all install completions expose --local" {
    // Regression guard: once a flag is shipped it must survive CLI edits
    // to every shell script, not just bash.
    try expectContains(completions.bash_script, "--local");
    try expectContains(completions.zsh_script, "--local");
    try expectContains(completions.fish_script, "-l local");
}

test "all outdated completions expose --refresh" {
    try expectContains(completions.bash_script, "--refresh");
    try expectContains(completions.zsh_script, "--refresh");
    try expectContains(completions.fish_script, "-l refresh");
}

test "all doctor completions offer the --fix class ids" {
    // The `--fix <id>` selector is only discoverable if each shell
    // offers the safe-fix class ids as completion candidates. All three
    // embed the same space-joined id list, so one needle pins them all.
    const ids = "stale_lock orphaned_store broken_symlinks";
    try expectContains(completions.bash_script, ids);
    try expectContains(completions.zsh_script, ids);
    try expectContains(completions.fish_script, ids);
}

test "all outdated completions expose --tap" {
    // bash carries `--tap` in the outdated cmd_flags list; zsh's
    // per-command _arguments block names it with a `:tap label:` slot;
    // fish declares it with `-x` so the next token is treated as the
    // label and not eaten by file completion.
    // Scoped to outdated's own flag list rather than pinning the whole string,
    // which broke whenever an unrelated flag was added to the same line.
    try expectContains(try bashFlagsFor("outdated)"), "--tap");
    try expectContains(completions.zsh_script, "'--tap[Only packages from <label> (e.g. user/repo)]:tap label:'");
    try expectContains(completions.fish_script, "'__malt_using_command outdated' -l tap");
}

test "all update completions expose --check" {
    try expectContains(completions.bash_script, "--check");
    try expectContains(completions.zsh_script, "--check");
    try expectContains(completions.fish_script, "-l check");
}

test "all global-flag completions expose --output-format=ndjson" {
    // Regression guard: ndjson is a global flag, so every shell's
    // top-level flag list must include it. Tab-completion on the
    // mutating commands is a primary user surface.
    try expectContains(completions.bash_script, "--output-format=ndjson");
    try expectContains(completions.zsh_script, "--output-format=ndjson");
    try expectContains(completions.fish_script, "output-format=ndjson");
}

test "all global-flag completions expose --debug" {
    // Regression guard: --debug is a global flag (help + man + README),
    // so every shell's top-level flag list must offer it. It was missing
    // from all three scripts until parity with the help banner was restored.
    try expectContains(completions.bash_script, "--debug");
    try expectContains(completions.zsh_script, "--debug[");
    try expectContains(completions.fish_script, "-l debug");
}

test "purge completions expose --verbose with command-specific semantics" {
    // --verbose is a global flag, so bash/fish pick it up automatically;
    // zsh's per-command _arguments block has to declare it locally so the
    // help string explains what it means inside `mt purge`.
    try expectContains(completions.bash_script, "--verbose -v");
    try expectContains(completions.fish_script, "-l verbose");
    try expectContains(completions.zsh_script, "Show every per-scope item");
}

test "purge completions surface --json and --output-format=ndjson" {
    // Same shape as --verbose: bash and fish merge global flags into the
    // per-subcommand list automatically; zsh's per-command _arguments
    // block has to declare them locally or `mt purge --<TAB>` won't
    // discover them.
    try expectContains(completions.zsh_script, "Single summary object on stdout for scripts");
    try expectContains(completions.zsh_script, "Stream one event per scope start/complete");
    // Bash global_flags list and fish unconditional completes already
    // cover both flags; pin them here so a regression in the global slot
    // surfaces as a purge-specific failure.
    try expectContains(completions.bash_script, "--output-format=ndjson");
    try expectContains(completions.fish_script, "output-format=ndjson");
}

test "all completions expose reinstall as a top-level verb" {
    // Substring presence isn't enough — `restore`/`reinstall` overlap
    // English-wise, so pin the per-shell token shapes used for the
    // top-level command row.
    try expectContains(completions.bash_script, "install reinstall uninstall");
    try expectContains(completions.zsh_script, "'reinstall:");
    try expectContains(completions.fish_script, "__malt_needs_command -a reinstall");
}

test "all completions expose tui as a top-level verb" {
    // The dashboard is only reachable by tab-completion if every shell lists
    // `tui` in its top-level verb set. `tui` is a unique token, but pin the
    // per-shell row shapes so a regression surfaces as a tui-specific failure.
    try expectContains(completions.bash_script, "services tui bundle");
    try expectContains(completions.zsh_script, "'tui:");
    try expectContains(completions.fish_script, "-a tui ");
}

test "all completions expose cleanup as a top-level verb" {
    // `cleanup` already appears in every script as a `bundle cleanup`
    // subcommand, so substring presence isn't enough — pin the
    // top-level token shapes each shell uses for the verbs row.
    try expectContains(completions.bash_script, "list ls info search uses deps which doctor tap untap migrate rollback link unlink pin unpin run version completions shellenv backup restore purge cleanup");
    try expectContains(completions.zsh_script, "'cleanup:");
    try expectContains(completions.fish_script, "__malt_needs_command -a cleanup");
}

test "all bundle completions expose the cleanup subcommand and its flags" {
    for ([_][]const u8{
        completions.bash_script,
        completions.zsh_script,
        completions.fish_script,
    }) |script| try expectContains(script, "cleanup");
    // --yes belongs to cleanup; --dry-run is shared with install.
    try expectContains(completions.bash_script, "--yes");
    try expectContains(completions.zsh_script, "cleanup[");
    try expectContains(completions.fish_script, "-l yes");
}

test "version completions expose the update flags across every shell" {
    // `mt version update` has a documented flag set; the completions
    // must surface it so the self-updater is discoverable without --help.
    try expectContains(completions.bash_script, "--no-verify");
    try expectContains(completions.zsh_script, "--no-verify[");
    try expectContains(completions.fish_script, "-l no-verify");
    try expectContains(completions.fish_script, "-l cleanup");
}

test "backup completions expose --services across every shell" {
    // `mt backup --services` is the user-visible verb that closes the
    // launchd-bootstrap round-trip; the completions must surface it so
    // it's discoverable without consulting --help.
    try expectContains(completions.bash_script, "--services");
    try expectContains(completions.zsh_script, "'--services[");
    try expectContains(completions.fish_script, "-l services");
}

test "help completions offer command topics across every shell" {
    // `mt help <cmd>` takes a command topic; each shell must suggest the
    // command names after `help` so topics are discoverable.
    try expectContains(completions.bash_script, "help)");
    try expectContains(completions.zsh_script, "help)");
    try expectContains(completions.fish_script, "__malt_using_command help");
}

test "all install, migrate, and upgrade completions expose --use-system-ruby" {
    // The scoped Ruby fallback exists on all three commands; each shell
    // must offer it wherever the command accepts it.
    try expectContains(completions.bash_script, "--use-system-ruby=");
    try expectContains(completions.zsh_script, "--use-system-ruby=");
    try expectContains(completions.fish_script, "-l use-system-ruby");
    inline for (.{ completions.bash_script, completions.zsh_script, completions.fish_script }) |script| {
        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, script, pos, "use-system-ruby")) |i| {
            count += 1;
            pos = i + 1;
        }
        // install + migrate + upgrade, once per command minimum.
        try std.testing.expect(count >= 3);
    }
}

/// Slice a script between `start` and the next `end`. Flag assertions have to
/// be scoped to one command's block: a bare `indexOf("--services")` over the
/// whole script is satisfied by `backup --services` and proves nothing about
/// `bundle`.
fn sectionAfter(script: []const u8, start: []const u8, end: []const u8) ![]const u8 {
    const s = std.mem.indexOf(u8, script, start) orelse return error.MissingSectionStart;
    const rest = script[s + start.len ..];
    const e = std.mem.indexOf(u8, rest, end) orelse return error.MissingSectionEnd;
    return rest[0..e];
}

/// The bash per-command flag table, excluding the earlier positional-completion
/// `case`, which also has `bundle)` and `services)` labels.
fn bashFlagsFor(command: []const u8) ![]const u8 {
    const table = try sectionAfter(completions.bash_script, "local cmd_flags=\"\"", "esac");
    return sectionAfter(table, command, "\n");
}

fn zshCaseFor(command: []const u8) ![]const u8 {
    return sectionAfter(completions.zsh_script, command, ";;");
}

test "bundle completions advertise only flags bundle.zig parses" {
    // --from-installed was advertised for a mode that does not exist: `bundle
    // create` always populates from installed, so the flag could never change
    // anything. Its absence is the assertion.
    try testing.expect(std.mem.indexOf(u8, completions.bash_script, "from-installed") == null);
    try testing.expect(std.mem.indexOf(u8, completions.zsh_script, "from-installed") == null);
    try testing.expect(std.mem.indexOf(u8, completions.fish_script, "from-installed") == null);
}

test "all bundle completions expose --services" {
    try expectContains(try bashFlagsFor("bundle)"), "--services");
    try expectContains(try zshCaseFor("                bundle)"), "'--services[");
    try expectContains(completions.fish_script, "__malt_using_command bundle' -l services");
}

test "all bundle completions expose --purge" {
    try expectContains(try bashFlagsFor("bundle)"), "--purge");
    try expectContains(try zshCaseFor("                bundle)"), "'--purge[");
    try expectContains(completions.fish_script, "__malt_using_command bundle' -l purge");
}

test "all migrate completions expose --parallel" {
    try expectContains(try bashFlagsFor("migrate)"), "--parallel");
    try expectContains(try zshCaseFor("                migrate)"), "'--parallel[");
    try expectContains(completions.fish_script, "__malt_using_command migrate'    -l parallel");
}

test "zsh completes uses and deps flags" {
    // zsh had no case for either command, so it fell through to no completion
    // at all while bash and fish offered flags.
    const uses = try zshCaseFor("                uses)");
    try expectContains(uses, "--recursive");
    try expectContains(uses, "--json");

    const deps = try zshCaseFor("                deps)");
    try expectContains(deps, "--recursive");
    try expectContains(deps, "--installed");
    try expectContains(deps, "--json");
}

test "zsh services completions offer flags alongside the subcommands" {
    const services = try zshCaseFor("                services)");
    try expectContains(services, "--tail");
    try expectContains(services, "--stderr");
    try expectContains(services, "--follow");
    // The subcommands must survive the switch from _values to _arguments.
    try expectContains(services, "list start stop restart status logs");
}

test "zsh bundle completions offer flags alongside the subcommands" {
    const bundle = try zshCaseFor("                bundle)");
    try expectContains(bundle, "--dry-run");
    try expectContains(bundle, "--format");
    try expectContains(bundle, "install cleanup create list remove export import");
}

test "fish ls alias completes the same flags as list" {
    // `ls` is an alias of `list` (main.zig command table), so a user who types
    // the short form must not silently lose --tap/--size/--linked.
    for ([_][]const u8{ "versions", "formula", "cask", "pinned", "tap", "json", "size", "linked" }) |flag| {
        var buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "__malt_using_command ls'   -l {s}", .{flag});
        try expectContains(completions.fish_script, needle);
    }
}

test "zsh line continuations are single backslashes" {
    // Zig multiline literals do no escape processing, so a doubled backslash
    // reaches zsh as an escaped backslash rather than a continuation: the
    // command ends early and the remaining flag specs run as commands. This
    // parses cleanly under `zsh -n`, so only a shape check catches it.
    var it = std.mem.splitScalar(u8, completions.zsh_script, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t");
        if (std.mem.endsWith(u8, trimmed, "\\\\")) {
            std.debug.print("doubled backslash continuation: '{s}'\n", .{trimmed});
            return error.DoubledBackslash;
        }
    }
}

test "no shell advertises the removed phantom flags" {
    // uninstall --zap, services --system and upgrade --all were offered by the
    // shells but read by no parser. Their absence is the assertion.
    inline for (.{ completions.bash_script, completions.zsh_script, completions.fish_script }) |script| {
        try testing.expect(std.mem.indexOf(u8, script, "zap") == null);
        try testing.expect(std.mem.indexOf(u8, script, "--system") == null);
        try testing.expect(std.mem.indexOf(u8, script, "-l system") == null);
    }
    // `--all` is scoped: search, tap and link keep their real ones.
    try expectNotContains(try bashFlagsFor("upgrade)"), "--all");
    try expectNotContains(try zshCaseFor("                upgrade)"), "'--all[");
    try testing.expect(std.mem.indexOf(u8, completions.fish_script, "__malt_using_command upgrade' -l all") == null);
    try expectContains(try bashFlagsFor("search)"), "--all");
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("expected section to NOT contain '{s}'\n", .{needle});
        return error.UnexpectedSubstring;
    }
}
