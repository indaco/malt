//! malt — shellenv command
//! Match brew's shellenv contract so `eval "$(mt shellenv)"` works in place
//! of the brew form during onboarding.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const atomic = @import("../fs/atomic.zig");
const io_mod = @import("../ui/io.zig");
const help = @import("help.zig");

pub const Shell = enum { bash, zsh, fish };

pub fn parseShell(name: []const u8) ?Shell {
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "zsh")) return .zsh;
    if (std.mem.eql(u8, name, "fish")) return .fish;
    return null;
}

pub fn detectFromShellPath(value: ?[]const u8) ?Shell {
    const path = value orelse return null;
    if (path.len == 0) return null;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const base = if (slash) |i| path[i + 1 ..] else path;
    return parseShell(base);
}

/// Caller owns the returned slice.
pub fn render(
    allocator: std.mem.Allocator,
    shell: Shell,
    prefix: []const u8,
) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    // The writer is allocator-backed, so its `WriteFailed` is always OOM.
    writeShellEnv(&aw.writer, shell, prefix) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeShellEnv(w: *std.Io.Writer, shell: Shell, prefix: []const u8) std.Io.Writer.Error!void {
    // Fish uses `set -gx` because `export` is a syntax error in fish;
    // bash/zsh share the POSIX form.
    switch (shell) {
        .bash, .zsh => {
            try w.print("export HOMEBREW_PREFIX=\"{s}\";\n", .{prefix});
            try w.print("export HOMEBREW_CELLAR=\"{s}/Cellar\";\n", .{prefix});
            try w.print("export HOMEBREW_REPOSITORY=\"{s}\";\n", .{prefix});
            try w.print("export PATH=\"{s}/bin:{s}/sbin${{PATH+:$PATH}}\";\n", .{ prefix, prefix });
            try w.print("export MANPATH=\"{s}/share/man${{MANPATH+:$MANPATH}}:\";\n", .{prefix});
            try w.print("export INFOPATH=\"{s}/share/info:${{INFOPATH:-}}\";\n", .{prefix});
        },
        .fish => {
            try w.print("set -gx HOMEBREW_PREFIX \"{s}\";\n", .{prefix});
            try w.print("set -gx HOMEBREW_CELLAR \"{s}/Cellar\";\n", .{prefix});
            try w.print("set -gx HOMEBREW_REPOSITORY \"{s}\";\n", .{prefix});
            try w.print("set -gx PATH \"{s}/bin\" \"{s}/sbin\" $PATH;\n", .{ prefix, prefix });
            try w.print("set -gx MANPATH \"{s}/share/man\" $MANPATH;\n", .{prefix});
            try w.print("set -gx INFOPATH \"{s}/share/info\" $INFOPATH;\n", .{prefix});
        },
    }
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "shellenv")) return;

    const shell = resolveShell(args) orelse std.process.exit(2);

    const out = try render(allocator, shell, atomic.maltPrefix());
    defer allocator.free(out);
    io_mod.stdoutWriteAll(out);
}

fn resolveShell(args: []const []const u8) ?Shell {
    if (args.len > 0) {
        if (parseShell(args[0])) |s| return s;
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "malt: unknown shell '{s}'. Supported: bash, zsh, fish\n",
            .{args[0]},
        ) catch "malt: unknown shell. Supported: bash, zsh, fish\n";
        io_mod.stderrWriteAll(msg);
        return null;
    }
    if (detectFromShellPath(fs_compat.getenv("SHELL"))) |s| return s;
    io_mod.stderrWriteAll(
        "malt: could not detect shell from $SHELL. Pass bash, zsh, or fish explicitly.\n",
    );
    return null;
}
