//! Single source of `std.Io` and `Environ` for the process. Built in `main`
//! from `std.process.Init.Minimal` and threaded down so subcommands stop
//! reaching for module-level globals (`io_mod.ctx()`, `std.c.environ`).

const std = @import("std");
const builtin = @import("builtin");

pub const AppCtx = struct {
    io: std.Io,
    environ: std.process.Environ,
};

/// Parent `environ` as `std.process.Environ`, read directly from
/// `std.c.environ`. Production `main` builds an AppCtx from
/// `std.process.Init.Minimal` instead — this helper is for integration
/// tests that need to spawn children with the real PATH (`/opt/homebrew/bin`,
/// etc.) without threading an init through every test fixture.
pub fn processEnviron() std.process.Environ {
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    const slice: [:null]const ?[*:0]const u8 = @ptrCast(std.c.environ[0..n :null]);
    return .{ .block = .{ .slice = slice } };
}

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
