//! malt — shellenv command
//! Match brew's shellenv contract so `eval "$(mt shellenv)"` works in place
//! of the brew form during onboarding.

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
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

/// Caller owns the returned slice. `cert_present` gates the
/// `SSL_CERT_FILE` line: emit it only when the CA bundle exists so the
/// var never points at a missing file.
pub fn render(
    allocator: std.mem.Allocator,
    shell: Shell,
    prefix: []const u8,
    cert_present: bool,
) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    // The writer is allocator-backed, so its `WriteFailed` is always OOM.
    writeShellEnv(&aw.writer, shell, prefix, cert_present) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeShellEnv(w: *std.Io.Writer, shell: Shell, prefix: []const u8, cert_present: bool) std.Io.Writer.Error!void {
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
            if (cert_present) try w.print("export SSL_CERT_FILE=\"{s}/etc/openssl@3/cert.pem\";\n", .{prefix});
        },
        .fish => {
            try w.print("set -gx HOMEBREW_PREFIX \"{s}\";\n", .{prefix});
            try w.print("set -gx HOMEBREW_CELLAR \"{s}/Cellar\";\n", .{prefix});
            try w.print("set -gx HOMEBREW_REPOSITORY \"{s}\";\n", .{prefix});
            try w.print("set -gx PATH \"{s}/bin\" \"{s}/sbin\" $PATH;\n", .{ prefix, prefix });
            try w.print("set -gx MANPATH \"{s}/share/man\" $MANPATH;\n", .{prefix});
            try w.print("set -gx INFOPATH \"{s}/share/info\" $INFOPATH;\n", .{prefix});
            if (cert_present) try w.print("set -gx SSL_CERT_FILE \"{s}/etc/openssl@3/cert.pem\";\n", .{prefix});
        },
    }
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "shellenv")) return;

    const shell = resolveShell(ctx, args) orelse std.process.exit(2);

    const prefix = atomic.maltPrefixOrAbort();
    const out = try render(allocator, shell, prefix, sslCertPresent(ctx.io, prefix));
    defer allocator.free(out);
    output.writeStdoutAll(out);
}

/// True when the OpenSSL CA bundle exists at the canonical path. Drives
/// the `SSL_CERT_FILE` export so it never names a missing file.
fn sslCertPresent(io: std.Io, prefix: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/etc/openssl@3/cert.pem", .{prefix}) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn resolveShell(ctx: *const AppCtx, args: []const []const u8) ?Shell {
    if (args.len > 0) {
        if (parseShell(args[0])) |s| return s;
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "malt: unknown shell '{s}'. Supported: bash, zsh, fish\n",
            .{args[0]},
        ) catch "malt: unknown shell. Supported: bash, zsh, fish\n";
        output.writeStderrAll(msg);
        return null;
    }
    if (detectFromShellPath(std.process.Environ.getPosix(ctx.environ, "SHELL"))) |s| return s;
    output.writeStderrAll(
        "malt: could not detect shell from $SHELL. Pass bash, zsh, or fish explicitly.\n",
    );
    return null;
}
