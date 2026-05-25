//! Single source of `std.Io`, stdio sinks, and `Environ` for the process.
//! Built in `main` from `std.process.Init.Minimal` and threaded down so
//! subcommands stop reaching for module-level globals.
//!
//! Boundary policy: `AppCtx` is a CLI-layer aggregate. `cli/*` and `update/*`
//! take `*const AppCtx`; `core/*` takes raw `std.Io` and
//! `std.process.Environ` parameters by design — no stdio, no AppCtx.
//! Keeping core library-shaped lets unit tests drive it with `debug_io`
//! and an empty environ without ever staging a process context.

const std = @import("std");
const builtin = @import("builtin");
const mirror = @import("net/mirror.zig");

pub const AppCtx = struct {
    io: std.Io,
    environ: std.process.Environ,
    /// Default `-1` so any cli/ui write that lands without a seeded sink
    /// fails as `BadFileDescriptor` rather than corrupting the test
    /// runner's IPC on fd 1. `main` seeds real stdout/stderr in production;
    /// tests opt in to a captured or `/dev/null` sink as needed.
    stdout: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } },
    stderr: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } },
    /// Process-wide mirror snapshot resolved once in `main`. cli/ call
    /// sites read this instead of re-walking the env per request;
    /// tests and `debug_ctx` get the upstream Homebrew defaults.
    mirrors: mirror.Mirrors = .{},
    /// `MALT_OFFLINE=1` or `--offline`. When true, every net/* call
    /// must serve from the snapshot cache and surface `OfflineRequired`
    /// on a miss rather than waiting for a connect timeout. Resolved
    /// once at boot so per-call sites read a single bool.
    offline: bool = false,
};

/// Parent `environ` as `std.process.Environ`. Production `main` builds an
/// AppCtx from `std.process.Init.Minimal`; this helper is for integration
/// tests that need the real PATH without threading an init through every
/// fixture. Zig 0.16 has no `std.process` seam that wraps libc `environ`
/// on POSIX — `Block` resolves to `PosixBlock` whose only field is `slice`,
/// so the bootstrap walks `std.c.environ` to its sentinel like stdlib's
/// own `start.zig` does.
pub fn processEnviron() std.process.Environ {
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    return .{ .block = .{ .slice = std.c.environ[0..n :null] } };
}

/// Test-only borrowed ctx with `debug_io` and an empty environ. Plenty
/// for argv-parsing / dry-run / help paths and any pure-fs probe that
/// only needs blocking syscalls — no spawn, no env lookup. Stdio fields
/// default to `-1` so writes silently fail under tests.
pub const debug_ctx: AppCtx = .{ .io = std.Options.debug_io, .environ = .empty };

test "AppCtx round-trips environ for getPosix lookups" {
    const entries = [_:null]?[*:0]const u8{"FOO=bar".ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const ctx: AppCtx = .{ .io = std.Options.debug_io, .environ = environ };
    try std.testing.expectEqualStrings("bar", std.process.Environ.getPosix(ctx.environ, "FOO").?);
}

test "debug_ctx returns null for any environ lookup" {
    if (!builtin.is_test) return;
    try std.testing.expect(std.process.Environ.getPosix(debug_ctx.environ, "PATH") == null);
}

test "debug_ctx stdio defaults are sentinel -1" {
    try std.testing.expectEqual(@as(std.c.fd_t, -1), debug_ctx.stdout.handle);
    try std.testing.expectEqual(@as(std.c.fd_t, -1), debug_ctx.stderr.handle);
}

test "AppCtx.offline defaults to false" {
    try std.testing.expect(!debug_ctx.offline);
}

test "AppCtx round-trips an explicit offline=true" {
    const ctx: AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .offline = true,
    };
    try std.testing.expect(ctx.offline);
}
