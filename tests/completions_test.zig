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
    "install",    "uninstall", "remove",      "upgrade",
    "update",     "outdated",  "list",        "ls",
    "info",       "search",    "cleanup",     "doctor",
    "tap",        "untap",     "gc",          "migrate",
    "autoremove", "rollback",  "link",        "unlink",
    "run",        "version",   "completions", "backup",
    "restore",
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
