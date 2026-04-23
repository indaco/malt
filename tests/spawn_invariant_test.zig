//! malt — argv-only spawn invariant
//!
//! Locks in Finding #4 of the 2026-04-17 audit: all Zig-side process
//! spawns pass through argv-style APIs (`fs_compat.Child.init`,
//! `std.process.spawn`), and never take the `sh -c <string>` /
//! `/bin/sh` shortcut. This test is a grep against the repo tree — if
//! a future change reintroduces a shell invocation, `zig build test`
//! fails loudly.
//!
//! The CI grep (`scripts/lint-spawn-invariants.sh`) runs the same
//! check at PR time; this one keeps the guard local to `zig build
//! test` so offline development catches regressions without waiting
//! on CI.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const fs_compat = malt.fs_compat;

fn isBanned(line: []const u8) bool {
    const banned = [_][]const u8{
        "sh -c",        "bash -c",      "zsh -c",
        "/bin/sh",      "/bin/bash",    "/bin/zsh",
        "/bin/ksh",     "/usr/bin/sh",  "/usr/bin/bash",
        "/usr/bin/zsh", "/usr/bin/ksh",
    };
    for (banned) |b| if (std.mem.indexOf(u8, line, b) != null) return true;
    return false;
}

fn stripLineComment(line: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, line, "//") orelse return line;
    return line[0..idx];
}

// Files in src/core/services/plist.zig legitimately name the forbidden
// interpreter paths in forbidden_heads — they're the *rejection list*
// for formula-declared services. Exempt that exact context.
fn allowedContext(path: []const u8, line: []const u8) bool {
    if (std.mem.endsWith(u8, path, "core/services/plist.zig")) {
        // forbidden_heads declaration + error docstrings — both live in
        // that file by design. Any other usage still has to pass.
        if (std.mem.indexOf(u8, line, "forbidden_heads") != null) return true;
        // Quoted-string list entries: `"/bin/sh",`
        if (std.mem.indexOf(u8, line, "\"/bin/") != null) return true;
        if (std.mem.indexOf(u8, line, "\"/usr/bin/") != null) return true;
    }
    return false;
}

test "no shell-invocation patterns anywhere under src/" {
    const alloc = testing.allocator;
    // Walk src/ from the project root. Tests run with CWD at project
    // root per build.zig conventions.
    var dir = try fs_compat.cwd().openDir("src", .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var violations: std.ArrayList(u8) = .empty;
    defer violations.deinit(alloc);

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const f = try entry.dir.openFile(malt.io_mod.ctx(), entry.basename, .{});
        defer f.close(malt.io_mod.ctx());
        const src = try fs_compat.readFileToEndAlloc(f, alloc, 4 * 1024 * 1024);
        defer alloc.free(src);

        var it = std.mem.splitScalar(u8, src, '\n');
        var lineno: usize = 0;
        while (it.next()) |line| {
            lineno += 1;
            const stripped = stripLineComment(line);
            if (!isBanned(stripped)) continue;
            if (allowedContext(entry.path, stripped)) continue;
            const buf = try std.fmt.allocPrint(
                alloc,
                "src/{s}:{d}: {s}\n",
                .{ entry.path, lineno, line },
            );
            defer alloc.free(buf);
            try violations.appendSlice(alloc, buf);
        }
    }

    if (violations.items.len != 0) {
        std.debug.print(
            "argv-only spawn invariant violated:\n{s}\n",
            .{violations.items},
        );
        return error.TestUnexpectedResult;
    }
}
