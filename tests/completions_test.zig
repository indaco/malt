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
    try expectContains(completions.bash_script, "outdated)         cmd_flags=\"--json --formula --cask --pinned-only --tap");
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

test "backup completions expose --services across every shell" {
    // `mt backup --services` is the user-visible verb that closes the
    // launchd-bootstrap round-trip; the completions must surface it so
    // it's discoverable without consulting --help.
    try expectContains(completions.bash_script, "--services");
    try expectContains(completions.zsh_script, "'--services[");
    try expectContains(completions.fish_script, "-l services");
}
