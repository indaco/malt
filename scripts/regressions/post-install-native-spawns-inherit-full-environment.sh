#!/usr/bin/env bash
# Regression: the native post_install_steps executor spawned every child with
# `environ_map = null`. malt's Io is seeded from the real process environ, so
# null means *inherit everything*, not *inherit nothing*: a tap-controlled
# `run` binary saw MALT_*_TOKEN and the user's full PATH. The sandbox fence
# denies network but allows file writes under /tmp and the keg, `process-exec*`
# over that inherited PATH, and stdout is inherited straight into CI logs.
#
# The sibling spawn surfaces (the Ruby path and the DSL `system` builtin)
# already scrub. No CLI subcommand drives the executor without a network
# install, so a standalone `zig test` harness feeds it a synthetic formula
# whose `run` step dumps its own environment, and asserts the secret is gone,
# PATH is the minimal sandbox one, and an allowlisted locale var survives
# (a scrub, not a wipe).
#
# The harness MUST seed Threaded's environ: with the default `.empty` the
# child inherits nothing and the assertion passes on broken code.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STUBS=$(mktemp -d)

# The harness imports the executor via a repo-relative path, so it must sit at
# the repo root: the module's sibling imports (`dsl/sandbox.zig`,
# `../fs/atomic.zig`) only resolve from inside the source tree.
HARNESS="$ROOT/.post-install-env-scrub-regression.$$.zig"
trap 'rm -rf "$STUBS" "$HARNESS"' EXIT

# The executor's module graph reaches the clonefile/statfs bindings that
# build.zig generates with translate-c. Only the `copy` step calls them and
# this harness never runs one, so declarations are enough to link.
cat >"$STUBS/c_clonefile.zig" <<'ZIG'
pub extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: c_uint) c_int;
ZIG
cat >"$STUBS/c_mount.zig" <<'ZIG'
pub const struct_statfs = extern struct { f_fstypename: [16]u8 };
pub extern "c" fn statfs(path: [*:0]const u8, buf: *struct_statfs) c_int;
ZIG

cat >"$HARNESS" <<'ZIG'
const std = @import("std");
const steps = @import("src/core/post_install_steps.zig");
const macos_sandbox = @import("src/core/sandbox/macos.zig");

const secret = "MALT_GITHUB_TOKEN=probe-sentinel-do-not-leak";
const locale = "LANG=en_US.UTF-8";

test "a run step's child cannot see malt's own environment" {
    const environ: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{
        secret,
        locale,
        "PATH=/probe/attacker/bin:/usr/bin:/bin",
    } } };

    // Seeded exactly like main.zig: this is what `environ_map = null` inherits.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = path_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &path_buf)];

    const keg = try std.fmt.allocPrint(a, "{s}/Cellar/probe/1.0", .{prefix});
    const libexec = try std.fmt.allocPrint(a, "{s}/libexec", .{keg});
    try std.Io.Dir.cwd().createDirPath(io, libexec);
    try std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/etc", .{prefix}));

    const seen = try std.fmt.allocPrint(a, "{s}/etc/seen.txt", .{prefix});
    const script = try std.fmt.allocPrint(a, "{s}/post-install", .{libexec});
    {
        const f = try std.Io.Dir.createFileAbsolute(io, script, .{});
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.print("#!/bin/sh\n/usr/bin/env > '{s}'\n", .{seen});
        try w.interface.flush();
        try f.setPermissions(io, @enumFromInt(0o755));
    }

    var flog = steps.FallbackLog.init(std.testing.allocator);
    defer flog.deinit();
    const ctx: steps.StepsCtx = .{
        .io = io,
        .allocator = a,
        .name = "probe",
        .version = "1.0",
        .prefix = prefix,
        .keg_path = keg,
        .flog = &flog,
        .environ = environ,
    };

    const formula =
        \\{"name":"probe","versions":{"stable":"1.0"},"post_install_steps":
        \\[{"type":"run","command":{"base":"libexec","path":"post-install"}}]}
    ;
    try std.testing.expect(steps.execute(ctx, formula));

    const f = std.Io.Dir.openFileAbsolute(io, seen, .{}) catch return error.RunStepDidNotExecute;
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var r = f.reader(io, &.{});
    const dump = buf[0..try r.interface.readSliceShort(&buf)];

    if (std.mem.indexOf(u8, dump, "probe-sentinel") != null) {
        std.debug.print("child environment carried malt's forge token\n", .{});
        return error.ForgeTokenLeakedToPostInstallChild;
    }
    var it = std.mem.splitScalar(u8, dump, '\n');
    const got_path = while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "PATH=")) break line["PATH=".len..];
    } else "";
    if (!std.mem.eql(u8, got_path, macos_sandbox.sandbox_path)) {
        std.debug.print("want PATH '{s}', got '{s}'\n", .{ macos_sandbox.sandbox_path, got_path });
        return error.ParentPathLeakedToPostInstallChild;
    }
    // Proves the base is a scrub and not a wipe: build/locale keys still pass.
    if (std.mem.indexOf(u8, dump, locale) == null) {
        std.debug.print("allowlisted locale var did not reach the child\n", .{});
        return error.AllowlistedEnvDropped;
    }
}
ZIG

run_harness() {
  # ca_bundle.zig evaluates trust in-process; the module graph needs the
  # same frameworks build.zig links.
  (cd "$ROOT" && zig test -lc -framework Security -framework CoreFoundation \
    --dep c_clonefile --dep c_mount \
    -Mroot="$HARNESS" \
    -Mc_clonefile="$STUBS/c_clonefile.zig" \
    -Mc_mount="$STUBS/c_mount.zig")
}

if run_harness >/dev/null 2>&1; then
  echo "PASS: native post_install children get a scrubbed environment"
else
  run_harness 2>&1 | grep -Ev '\.\.\.OK$' | tail -20 >&2
  echo "FAIL: a native post_install child saw malt's environment (forge token / user PATH)" >&2
  exit 1
fi
