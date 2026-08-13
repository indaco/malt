#!/usr/bin/env bash
# Regression: a formula's declarative post-install output reached the terminal
# unfiltered. The `--use-system-ruby` path already pumped its child through the
# terminal sanitizer, but the native executor spawned with stdout inherited, so
# a formula could emit any escape the terminal acts on - OSC 52 clipboard
# writes, scrollback erase - straight from `malt install`.
#
# No CLI subcommand drives the executor without a network install, so a
# standalone `zig test` harness feeds it a synthetic formula whose `run` step
# emits an OSC 52 sequence followed by visible text. The sanitized bytes land
# on the harness process's own stdout, which this script captures: asserting
# from the shell keeps the check out of the in-process test runner, whose
# stdout is its own IPC channel.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STUBS=$(mktemp -d)

# The harness imports the executor via a repo-relative path, so it must sit at
# the repo root: the module's sibling imports only resolve inside the tree.
HARNESS="$ROOT/.post-install-output-sanitized-regression.$$.zig"
trap 'rm -rf "$STUBS" "$HARNESS"' EXIT

# Only the `copy` step calls these translate-c bindings and this harness never
# runs one, so declarations are enough to link.
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

test "a run step's output reaches the terminal sanitized" {
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

    // Emits an OSC 52 clipboard write followed by visible text, so the shell
    // can tell stripping from swallowing: the escape must go, the text stay.
    const script = try std.fmt.allocPrint(a, "{s}/post-install", .{libexec});
    {
        const f = try std.Io.Dir.createFileAbsolute(io, script, .{});
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.print("#!/bin/sh\nprintf '\\033]52;c;cHduZWQ=\\007SENTINEL-VISIBLE\\n'\n", .{});
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
        \\[{"type":"run","command":{"base":"libexec","path":"post-install"}}]}
    ;
    try std.testing.expect(steps.execute(ctx, formula));
}
ZIG

run_harness() {
  # ca_bundle.zig evaluates trust in-process; the module graph needs the same
  # frameworks build.zig links.
  (cd "$ROOT" && zig test -lc -framework Security -framework CoreFoundation \
    --dep c_clonefile --dep c_mount \
    -Mroot="$HARNESS" \
    -Mc_clonefile="$STUBS/c_clonefile.zig" \
    -Mc_mount="$STUBS/c_mount.zig")
}

# The child's sanitized bytes arrive on the harness's stdout; the test runner's
# own chatter goes to stderr and is dropped.
if ! captured=$(run_harness 2>/dev/null); then
  run_harness 2>&1 | grep -Ev '\.\.\.OK$' | tail -20 >&2
  echo "FAIL: the harness could not run the declarative step" >&2
  exit 1
fi

if ! printf '%s' "$captured" | grep -q 'SENTINEL-VISIBLE'; then
  echo "FAIL: sanitizing swallowed the step's legitimate output" >&2
  exit 1
fi

if printf '%s' "$captured" | LC_ALL=C grep -q $'\033'; then
  echo "FAIL: a declarative post-install step leaked a terminal escape" >&2
  exit 1
fi

echo "PASS: declarative post-install output reaches the terminal sanitized"
