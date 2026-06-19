//! malt — launchd plist emitter
//!
//! Generates Apple plist XML for loading a service under launchd. Output is
//! deterministic (fixed key order) so golden tests can byte-compare.

const std = @import("std");
const testing = std.testing;

const dsl_sandbox = @import("../dsl/sandbox.zig");
const types = @import("types.zig");

pub const Schedule = types.Schedule;
pub const CalendarInterval = types.CalendarInterval;

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
    schedule: Schedule = .immediate,
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
    /// schedule is `.interval` with a zero or out-of-range second count.
    BadSchedule,
};

/// Cap on argv count. Real launchd services carry fewer than a dozen.
pub const max_program_args: usize = 64;
/// Cap on a single argv or path string.
pub const max_arg_len: usize = 4096;
/// Upper bound on an interval schedule, in seconds (shared with the parser).
pub const max_interval_secs = types.max_interval_secs;
/// Cap on calendar entries (shared with the cron parser).
pub const max_calendar_entries = types.max_calendar_entries;

/// The Homebrew API renders every service path with this literal token rather
/// than the resolved prefix (`$HOMEBREW_PREFIX/opt/redis/bin/redis-server`).
pub const homebrew_prefix_token = "$HOMEBREW_PREFIX";

/// Resolve `$HOMEBREW_PREFIX` to malt's install prefix in a service string.
/// launchd does not expand environment variables in `ProgramArguments`, and the
/// token resolves to the *default Homebrew* prefix, not malt's — so without this
/// every real formula's `service:` block fails `validate` (its executable head
/// is not an absolute path under the malt prefix). Replaces every occurrence;
/// returns an owned copy the caller frees.
pub fn expandPrefix(allocator: std.mem.Allocator, s: []const u8, prefix: []const u8) std.mem.Allocator.Error![]u8 {
    const size = std.mem.replacementSize(u8, s, homebrew_prefix_token, prefix);
    const out = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, s, homebrew_prefix_token, prefix, out);
    return out;
}

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

    switch (spec.schedule) {
        .immediate => {},
        .interval => |secs| if (secs == 0 or secs > max_interval_secs)
            return ValidationError.BadSchedule,
        // Defence in depth: reject an empty or over-cap entry list, or any
        // field out of range, even though the cron parser already bounds these.
        .calendar => |entries| {
            if (entries.len == 0 or entries.len > max_calendar_entries)
                return ValidationError.BadSchedule;
            for (entries) |ci| if (!calInRange(ci)) return ValidationError.BadSchedule;
        },
    }

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

/// True when every set field of a CalendarInterval sits in launchd's range.
/// Weekday allows 0–7 (both 0 and 7 are Sunday).
fn calInRange(ci: CalendarInterval) bool {
    if (ci.minute) |m| if (m > 59) return false;
    if (ci.hour) |h| if (h > 23) return false;
    if (ci.day) |d| if (d < 1 or d > 31) return false;
    if (ci.weekday) |w| if (w > 7) return false;
    if (ci.month) |mo| if (mo < 1 or mo > 12) return false;
    return true;
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

    // RunAtLoad is derived from the schedule. An interval job also gets a
    // StartInterval and, deliberately, no KeepAlive: relaunch-on-exit would
    // restart it immediately and defeat the interval.
    switch (spec.schedule) {
        .immediate => {
            try writer.writeAll("    <key>RunAtLoad</key>\n    <true/>\n");
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
        },
        .interval => |secs| {
            try writer.writeAll("    <key>RunAtLoad</key>\n    <false/>\n");
            try writer.writeAll("    <key>StartInterval</key>\n    <integer>");
            try writer.print("{d}", .{secs});
            try writer.writeAll("</integer>\n");
        },
        .calendar => |entries| {
            try writer.writeAll("    <key>RunAtLoad</key>\n    <false/>\n");
            try writer.writeAll("    <key>StartCalendarInterval</key>\n");
            // launchd accepts a bare dict for one entry; a list/step/range
            // expansion becomes an array of dicts it ORs together.
            if (entries.len == 1) {
                try writeCalDict(writer, entries[0], "    ");
            } else {
                try writer.writeAll("    <array>\n");
                for (entries) |ci| try writeCalDict(writer, ci, "        ");
                try writer.writeAll("    </array>\n");
            }
        },
    }

    try writer.writeAll("</dict>\n</plist>\n");
}

/// Emit one launchd `CalendarInterval` as a `<dict>` indented by `indent`.
/// Only set fields appear; values are validated integers, never formula text.
fn writeCalDict(writer: *std.Io.Writer, ci: CalendarInterval, indent: []const u8) !void {
    try writer.print("{s}<dict>\n", .{indent});
    try writeCalField(writer, indent, "Minute", ci.minute);
    try writeCalField(writer, indent, "Hour", ci.hour);
    try writeCalField(writer, indent, "Day", ci.day);
    try writeCalField(writer, indent, "Weekday", ci.weekday);
    try writeCalField(writer, indent, "Month", ci.month);
    try writer.print("{s}</dict>\n", .{indent});
}

fn writeCalField(writer: *std.Io.Writer, indent: []const u8, key: []const u8, value: ?u8) !void {
    const v = value orelse return;
    try writer.print("{s}    <key>{s}</key>\n{s}    <integer>{d}</integer>\n", .{ indent, key, indent, v });
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

test "expandPrefix resolves a leading token to malt's prefix" {
    const out = try expandPrefix(testing.allocator, "$HOMEBREW_PREFIX/opt/redis/bin/redis-server", "/opt/malt");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/opt/malt/opt/redis/bin/redis-server", out);
}

test "expandPrefix resolves a token embedded mid-argument" {
    const out = try expandPrefix(testing.allocator, "--datadir=$HOMEBREW_PREFIX/var/mysql", "/opt/malt");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("--datadir=/opt/malt/var/mysql", out);
}

test "expandPrefix resolves every occurrence in one string" {
    const out = try expandPrefix(testing.allocator, "$HOMEBREW_PREFIX/a:$HOMEBREW_PREFIX/b", "/opt/malt");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/opt/malt/a:/opt/malt/b", out);
}

test "expandPrefix resolves a token-only string" {
    const out = try expandPrefix(testing.allocator, "$HOMEBREW_PREFIX", "/opt/malt");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/opt/malt", out);
}

test "expandPrefix returns a token-free string unchanged" {
    const out = try expandPrefix(testing.allocator, "--daemonize", "/opt/malt");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("--daemonize", out);
}

test "expandPrefix returns an empty string unchanged" {
    const out = try expandPrefix(testing.allocator, "", "/opt/malt");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "expandPrefix matches the whole token, not a sibling Homebrew variable" {
    // `$HOMEBREW_CELLAR` shares a prefix with the token but must be left intact.
    const out = try expandPrefix(testing.allocator, "$HOMEBREW_CELLAR/redis", "/opt/malt");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("$HOMEBREW_CELLAR/redis", out);
}
