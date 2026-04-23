//! malt — launchd plist emitter
//!
//! Generates Apple plist XML for loading a service under launchd. Output is
//! deterministic (fixed key order) so golden tests can byte-compare.

const std = @import("std");
const dsl_sandbox = @import("../dsl/sandbox.zig");

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const ServiceSpec = struct {
    label: []const u8,
    program_args: []const []const u8,
    working_dir: ?[]const u8 = null,
    env: []const EnvPair = &.{},
    stdout_path: []const u8,
    stderr_path: []const u8,
    run_at_load: bool = true,
    keep_alive: bool = true,
};

pub const ValidationError = error{
    /// program_args was empty; launchd would reject it, but we should
    /// refuse earlier with a clearer error.
    Empty,
    /// program_args[0] is `/bin/sh`-style — the formula is trying to
    /// reach outside its own bin tree by invoking an interpreter.
    InterpreterBait,
    /// program_args[0] or working_dir / log paths point outside the
    /// formula's cellar and the shared malt_prefix/opt subtree.
    PathEscape,
    /// program_args carries more arguments than we're willing to
    /// shuttle through plist + launchctl. 64 is generous for any
    /// real service.
    TooManyArgs,
    /// A single argv or path string is longer than 4 KiB. Real launchd
    /// entries are a few hundred bytes end to end; anything larger is
    /// either a bug or an attempted overflow.
    ArgTooLong,
    /// An argv or path contains a NUL byte — splitting point for C
    /// string APIs and nonsensical in launchd.
    EmbeddedNul,
    /// program_args[0] is not an absolute path.
    RelativeExecutable,
};

/// Cap on argv count. Real launchd services carry fewer than a dozen.
pub const max_program_args: usize = 64;
/// Cap on a single argv or path string.
pub const max_arg_len: usize = 4096;

/// Reject launchd interpreters as the leading executable. If a formula
/// actually ships its own cellar-local `sh` it must invoke it via its
/// cellar path — not `/bin/sh`, which launchd would happily run with
/// whatever argv follows.
const forbidden_heads = std.StaticStringMap(void).initComptime(.{
    .{ "/bin/sh", {} },
    .{ "/bin/bash", {} },
    .{ "/bin/zsh", {} },
    .{ "/bin/ksh", {} },
    .{ "/usr/bin/sh", {} },
    .{ "/usr/bin/bash", {} },
    .{ "/usr/bin/zsh", {} },
    .{ "/usr/bin/env", {} },
    .{ "/usr/bin/ksh", {} },
    .{ "/usr/bin/tcsh", {} },
    .{ "/usr/bin/python", {} },
    .{ "/usr/bin/perl", {} },
});

/// Validate a ServiceSpec before it's rendered to a plist. All writes
/// to disk and all `launchctl bootstrap` calls flow through this gate;
/// if a formula's `service:` block fails here, the install surfaces an
/// error instead of materialising an attacker-controlled LaunchAgent.
///
/// `cellar_path` is the formula's own keg directory (e.g.
/// `/opt/malt/Cellar/foo/1.0`). `malt_prefix` is the install prefix
/// (e.g. `/opt/malt`). Allowed executable locations:
///   - anywhere under `cellar_path`,
///   - anywhere under `malt_prefix/opt` (formula-scoped opt symlinks).
pub fn validate(
    spec: ServiceSpec,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) ValidationError!void {
    if (spec.program_args.len == 0) return ValidationError.Empty;
    if (spec.program_args.len > max_program_args) return ValidationError.TooManyArgs;

    for (spec.program_args) |a| try checkString(a);
    try checkString(spec.label);
    try checkString(spec.stdout_path);
    try checkString(spec.stderr_path);
    if (spec.working_dir) |wd| try checkString(wd);
    for (spec.env) |p| {
        try checkString(p.key);
        try checkString(p.value);
    }

    const head = spec.program_args[0];
    if (head.len == 0 or head[0] != '/') return ValidationError.RelativeExecutable;
    if (forbidden_heads.has(head)) return ValidationError.InterpreterBait;

    // Allowed roots: formula's own cellar, OR malt_prefix/opt. Both
    // checked with a component-boundary-aware prefix match so
    // `/opt/malt/evilopt/x` doesn't pass as `/opt/malt/opt`.
    var opt_buf: [512]u8 = undefined;
    const opt_prefix = std.fmt.bufPrint(&opt_buf, "{s}/opt", .{malt_prefix}) catch
        return ValidationError.PathEscape;

    if (!dsl_sandbox.pathHasPrefix(head, cellar_path) and
        !dsl_sandbox.pathHasPrefix(head, opt_prefix))
    {
        return ValidationError.PathEscape;
    }

    // Working dir and log paths: anywhere under cellar_path or
    // malt_prefix (var/log lives there). The DSL sandbox
    // validatePath already has the right rules; defer to it.
    for (&[_]?[]const u8{ spec.working_dir, spec.stdout_path, spec.stderr_path }) |maybe| {
        const p = maybe orelse continue;
        dsl_sandbox.validatePath(p, cellar_path, malt_prefix) catch
            return ValidationError.PathEscape;
    }
}

fn checkString(s: []const u8) ValidationError!void {
    if (s.len > max_arg_len) return ValidationError.ArgTooLong;
    if (std.mem.indexOfScalar(u8, s, 0) != null) return ValidationError.EmbeddedNul;
}

pub fn render(spec: ServiceSpec, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );

    try writer.writeAll("    <key>Label</key>\n    <string>");
    try writeEscaped(writer, spec.label);
    try writer.writeAll("</string>\n");

    try writer.writeAll("    <key>ProgramArguments</key>\n    <array>\n");
    for (spec.program_args) |arg| {
        try writer.writeAll("        <string>");
        try writeEscaped(writer, arg);
        try writer.writeAll("</string>\n");
    }
    try writer.writeAll("    </array>\n");

    if (spec.working_dir) |wd| {
        try writer.writeAll("    <key>WorkingDirectory</key>\n    <string>");
        try writeEscaped(writer, wd);
        try writer.writeAll("</string>\n");
    }

    if (spec.env.len > 0) {
        try writer.writeAll("    <key>EnvironmentVariables</key>\n    <dict>\n");
        for (spec.env) |pair| {
            try writer.writeAll("        <key>");
            try writeEscaped(writer, pair.key);
            try writer.writeAll("</key>\n        <string>");
            try writeEscaped(writer, pair.value);
            try writer.writeAll("</string>\n");
        }
        try writer.writeAll("    </dict>\n");
    }

    try writer.writeAll("    <key>StandardOutPath</key>\n    <string>");
    try writeEscaped(writer, spec.stdout_path);
    try writer.writeAll("</string>\n");

    try writer.writeAll("    <key>StandardErrorPath</key>\n    <string>");
    try writeEscaped(writer, spec.stderr_path);
    try writer.writeAll("</string>\n");

    try writer.writeAll("    <key>RunAtLoad</key>\n    ");
    try writer.writeAll(if (spec.run_at_load) "<true/>\n" else "<false/>\n");

    if (spec.keep_alive) {
        try writer.writeAll(
            \\    <key>KeepAlive</key>
            \\    <dict>
            \\        <key>SuccessfulExit</key>
            \\        <false/>
            \\    </dict>
            \\
        );
    }

    try writer.writeAll("</dict>\n</plist>\n");
}

fn writeEscaped(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(c),
        }
    }
}
