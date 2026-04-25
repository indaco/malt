//! malt — shellenv command tests

const std = @import("std");
const testing = std.testing;
const shellenv = @import("malt").shellenv;

test "parseShell recognises the three supported shells" {
    try testing.expectEqual(shellenv.Shell.bash, shellenv.parseShell("bash").?);
    try testing.expectEqual(shellenv.Shell.zsh, shellenv.parseShell("zsh").?);
    try testing.expectEqual(shellenv.Shell.fish, shellenv.parseShell("fish").?);
}

test "parseShell returns null for unknown shells" {
    try testing.expect(shellenv.parseShell("tcsh") == null);
    try testing.expect(shellenv.parseShell("ksh") == null);
    try testing.expect(shellenv.parseShell("") == null);
    try testing.expect(shellenv.parseShell("Bash") == null);
}

test "detectFromShellPath maps common $SHELL values to a shell" {
    try testing.expectEqual(shellenv.Shell.bash, shellenv.detectFromShellPath("/bin/bash").?);
    try testing.expectEqual(shellenv.Shell.zsh, shellenv.detectFromShellPath("/bin/zsh").?);
    try testing.expectEqual(shellenv.Shell.fish, shellenv.detectFromShellPath("/usr/local/bin/fish").?);
    try testing.expectEqual(shellenv.Shell.fish, shellenv.detectFromShellPath("/opt/homebrew/bin/fish").?);
}

test "detectFromShellPath returns null for missing or unknown shells" {
    try testing.expect(shellenv.detectFromShellPath(null) == null);
    try testing.expect(shellenv.detectFromShellPath("") == null);
    try testing.expect(shellenv.detectFromShellPath("/bin/tcsh") == null);
    try testing.expect(shellenv.detectFromShellPath("/usr/bin/sh") == null);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected output to contain '{s}', got:\n{s}\n", .{ needle, haystack });
        return error.MissingSubstring;
    }
}

test "render bash exports brew-compatible env so third-party scripts keep working" {
    const out = try shellenv.render(testing.allocator, .bash, "/opt/malt");
    defer testing.allocator.free(out);

    try expectContains(out, "export HOMEBREW_PREFIX=\"/opt/malt\"");
    try expectContains(out, "export HOMEBREW_CELLAR=\"/opt/malt/Cellar\"");
    try expectContains(out, "export HOMEBREW_REPOSITORY=\"/opt/malt\"");
    try expectContains(out, "export PATH=");
    try expectContains(out, "/opt/malt/bin");
    try expectContains(out, "/opt/malt/sbin");
    try expectContains(out, "export MANPATH=");
    try expectContains(out, "/opt/malt/share/man");
    try expectContains(out, "export INFOPATH=");
    try expectContains(out, "/opt/malt/share/info");
}

test "render bash and zsh emit byte-identical output (single shared arm)" {
    const bash = try shellenv.render(testing.allocator, .bash, "/opt/malt");
    defer testing.allocator.free(bash);
    const zsh = try shellenv.render(testing.allocator, .zsh, "/opt/malt");
    defer testing.allocator.free(zsh);
    try testing.expectEqualStrings(bash, zsh);
}

test "render bash prepends malt's bin before \\$PATH so its binaries win" {
    const out = try shellenv.render(testing.allocator, .bash, "/opt/malt");
    defer testing.allocator.free(out);
    // Binary order matters: an `append` would let the existing PATH shadow
    // malt-installed tools.
    try expectContains(out, "PATH=\"/opt/malt/bin:/opt/malt/sbin");
    // POSIX-safe expansion: empty PATH must stay empty, not become ":".
    try expectContains(out, "${PATH+:$PATH}");
}

test "render bash terminates every line with `;\\n` so eval sees full statements" {
    const out = try shellenv.render(testing.allocator, .bash, "/opt/malt");
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.endsWith(u8, out, ";\n"));
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(std.mem.endsWith(u8, line, ";"));
    }
}

test "render fish uses set -gx and avoids POSIX export syntax" {
    const out = try shellenv.render(testing.allocator, .fish, "/opt/malt");
    defer testing.allocator.free(out);

    try expectContains(out, "set -gx HOMEBREW_PREFIX \"/opt/malt\"");
    try expectContains(out, "set -gx HOMEBREW_CELLAR \"/opt/malt/Cellar\"");
    try expectContains(out, "set -gx HOMEBREW_REPOSITORY \"/opt/malt\"");
    try expectContains(out, "set -gx PATH \"/opt/malt/bin\" \"/opt/malt/sbin\" $PATH");
    try expectContains(out, "set -gx MANPATH \"/opt/malt/share/man\" $MANPATH");
    try expectContains(out, "set -gx INFOPATH \"/opt/malt/share/info\" $INFOPATH");
    // POSIX `export` and bash brace-expansion are syntax errors in fish.
    try testing.expect(std.mem.indexOf(u8, out, "export ") == null);
    try testing.expect(std.mem.indexOf(u8, out, "${") == null);
}

test "render honors a non-default prefix" {
    const out = try shellenv.render(testing.allocator, .bash, "/usr/local");
    defer testing.allocator.free(out);

    try expectContains(out, "export HOMEBREW_PREFIX=\"/usr/local\"");
    try expectContains(out, "/usr/local/bin");
    try testing.expect(std.mem.indexOf(u8, out, "/opt/malt") == null);
}

test "render surfaces allocator failure rather than swallowing it" {
    try testing.expectError(
        error.OutOfMemory,
        shellenv.render(testing.failing_allocator, .bash, "/opt/malt"),
    );
}

test "render with a tiny budget eventually returns OutOfMemory, not corruption" {
    // Exercises every partial-write path through `Writer.Allocating`.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        struct {
            fn run(a: std.mem.Allocator) !void {
                const out = try shellenv.render(a, .fish, "/opt/malt");
                a.free(out);
            }
        }.run,
        .{},
    );
}
