//! Single source of `std.Io` and `Environ` for the process. Built in `main`
//! from `std.process.Init.Minimal` and threaded down so subcommands stop
//! reaching for module-level globals (`io_mod.ctx()`, `std.c.environ`).

const std = @import("std");
const builtin = @import("builtin");

pub const AppCtx = struct {
    io: std.Io,
    environ: std.process.Environ,
};

/// Test-only borrowed ctx with `debug_io` and an empty environ. Plenty
/// for argv-parsing / dry-run / help paths and any pure-fs probe that
/// only needs blocking syscalls — no spawn, no env lookup.
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
