#!/usr/bin/env bash
# Regression: `run` is the most common declarative post-install step upstream,
# but it was missing from the executor's dispatch table. Every formula that
# declared one fell through to the unknown-step branch, so the install ended
# in the loud partial-skip envelope with the command never executed —
# ca-certificates never built its keychain-validated bundle, fontconfig never
# regenerated its cache. A second gap compounded it: `var` resolved as a path
# base but had no inline template mapping, so `{{var}}` reached the child
# process verbatim.
#
# No CLI subcommand drives the executor without a network install, so a
# standalone `zig test` harness feeds it a synthetic formula whose `run` step
# invokes a script staged in the keg's libexec, with `{{var}}` inside an
# argument. The script records the argument it received; the harness asserts
# the command ran, the token expanded, and the FallbackLog stayed clean.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STUBS=$(mktemp -d)

# The harness imports the executor via a repo-relative path, so it must sit at
# the repo root: the module's sibling imports (`dsl/sandbox.zig`,
# `../fs/atomic.zig`) only resolve from inside the source tree.
HARNESS="$ROOT/.post-install-run-step-regression.zig"
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

test "a run step executes the command with its templates expanded" {
    // A spawning Io: the debug one has no allocator for the child's argv.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
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

    // Echoes its first argument into a file the harness reads back, so the
    // assertion covers argument expansion and not just the exit code.
    const receipt = try std.fmt.allocPrint(a, "{s}/etc/receipt", .{prefix});
    const script = try std.fmt.allocPrint(a, "{s}/post-install", .{libexec});
    {
        const f = try std.Io.Dir.createFileAbsolute(io, script, .{});
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.print("#!/bin/sh\nprintf '%s' \"$1\" > '{s}'\n", .{receipt});
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
    };

    const formula =
        \\{"name":"probe","versions":{"stable":"1.0"},"post_install_steps":
        \\[{"type":"run","command":{"base":"libexec","path":"post-install"},
        \\  "args":["--ensure={{var}}/lib/machine-id"]}]}
    ;

    try std.testing.expect(steps.execute(ctx, formula));
    if (flog.hasErrors()) {
        for (flog.entries()) |e| std.debug.print("unexpected fallback: {s}\n", .{e.detail});
        return error.RunStepNotDispatched;
    }

    var got: [256]u8 = undefined;
    const f = std.Io.Dir.openFileAbsolute(io, receipt, .{}) catch return error.RunStepDidNotExecute;
    defer f.close(io);
    var r = f.reader(io, &.{});
    const n = try r.interface.readSliceShort(&got);
    const want = try std.fmt.allocPrint(a, "--ensure={s}/var/lib/machine-id", .{prefix});
    if (!std.mem.eql(u8, want, got[0..n])) {
        std.debug.print("want '{s}', got '{s}'\n", .{ want, got[0..n] });
        return error.VarTemplateNotExpanded;
    }
}
ZIG

run_harness() {
  (cd "$ROOT" && zig test -lc \
    --dep c_clonefile --dep c_mount \
    -Mroot="$HARNESS" \
    -Mc_clonefile="$STUBS/c_clonefile.zig" \
    -Mc_mount="$STUBS/c_mount.zig")
}

if run_harness >/dev/null 2>&1; then
  echo "PASS: run steps execute with their templates expanded"
else
  run_harness 2>&1 | grep -Ev '\.\.\.OK$' | tail -20 >&2
  echo "FAIL: a declarative run step did not execute as specified" >&2
  exit 1
fi
