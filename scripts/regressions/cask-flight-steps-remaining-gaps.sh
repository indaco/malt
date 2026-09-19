#!/usr/bin/env bash
# Regression: the native steps executor refused four live cask step shapes
# (`terminate_process` with match/attempts/notices/failure_message, `symlink`
# with uninstall, `run` with env) and never enforced `must_succeed`, so a
# cask declaring any of them was loud-skipped at install time and its
# symlinks survived its uninstall.
#
# Executor-only, offline: a standalone `zig test` harness imports the
# executor and drives each shape through `runSteps` / `checkSteps` /
# `runUninstallSteps`. The upgrade-time wiring of the phases is a CLI seam
# this harness cannot reach; `tests/cask_flight_steps_test.zig` covers it
# under `just test`.
#
# Exits 0 when every shape is honoured, non-zero with the failing assertion
# otherwise. No network; finishes well under 30s warm.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STUBS=$(mktemp -d)

# The harness imports the executor via a repo-relative path, so it must sit
# at the repo root for the module's sibling imports to resolve.
HARNESS="$ROOT/.cask-flight-gaps-regression.$$.zig"
trap 'rm -rf "$STUBS" "$HARNESS"' EXIT

# Only the `copy` step reaches the translate-c bindings; declarations link.
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

const Probe = struct {
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,
    flog: steps.FallbackLog,
    tmp: std.testing.TmpDir,
    prefix: []const u8,
    keg: []const u8,
    environ: std.process.Environ,

    fn init() !*Probe {
        const p = try std.testing.allocator.create(Probe);
        errdefer std.testing.allocator.destroy(p);
        p.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        p.flog = steps.FallbackLog.init(std.testing.allocator);
        p.tmp = std.testing.tmpDir(.{});
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const a = p.arena.allocator();
        p.prefix = try a.dupe(u8, path_buf[0..try std.Io.Dir.realPath(p.tmp.dir, std.Options.debug_io, &path_buf)]);
        const home = try a.allocSentinel(?[*:0]const u8, 1, null);
        home[0] = (try std.fmt.allocPrintSentinel(a, "HOME={s}", .{p.prefix}, 0)).ptr;
        p.environ = .{ .block = .{ .slice = home } };
        p.threaded = .init(std.testing.allocator, .{ .environ = p.environ });
        p.keg = try std.fmt.allocPrint(a, "{s}/Cellar/probe/1.0", .{p.prefix});
        try std.Io.Dir.cwd().createDirPath(p.threaded.io(), p.keg);
        return p;
    }

    fn ctx(p: *Probe) steps.StepsCtx {
        return .{
            .io = p.threaded.io(),
            .allocator = p.arena.allocator(),
            .name = "probe",
            .version = "1.0",
            .prefix = p.prefix,
            .keg_path = p.keg,
            .flog = &p.flog,
            .environ = p.environ,
        };
    }

    fn parse(p: *Probe, json: []const u8) ![]const std.json.Value {
        const parsed = try std.json.parseFromSlice(std.json.Value, p.arena.allocator(), json, .{});
        return parsed.value.array.items;
    }

    fn path(p: *Probe, sub: []const u8) ![]const u8 {
        return std.fmt.allocPrint(p.arena.allocator(), "{s}/{s}", .{ p.prefix, sub });
    }

    fn deinit(p: *Probe) void {
        p.threaded.deinit();
        p.tmp.cleanup();
        p.flog.deinit();
        p.arena.deinit();
        std.testing.allocator.destroy(p);
    }
};

fn exists(io: std.Io, p: []const u8) bool {
    return if (std.Io.Dir.accessAbsolute(io, p, .{})) |_| true else |_| false;
}

fn noteContains(flog: *const steps.FallbackLog, needle: []const u8) bool {
    for (flog.notes()) |n| if (std.mem.indexOf(u8, n, needle) != null) return true;
    return false;
}

test "a live terminate_process shape is not refused by the dry-run check" {
    var p = try Probe.init();
    defer p.deinit();
    steps.checkSteps(p.ctx(), try p.parse(
        \\[{"type":"terminate_process","name":"/Applications/zoom.us.app","match":"full","attempts":3,
        \\  "notices":["closing"],"failure_message":"could not close"}]
    ));
    if (p.flog.hasErrors()) {
        std.debug.print("refused: {s}\n", .{p.flog.entries()[0].detail});
        return error.TerminateProcessKeysRefused;
    }
}

test "a missed terminate_process reports its failure_message and carries on" {
    var p = try Probe.init();
    defer p.deinit();
    steps.runSteps(p.ctx(), try p.parse(
        \\[{"type":"terminate_process","name":"malt-gap-no-such-proc","match":"full","attempts":2,
        \\  "notices":["closing {{version}}"],"failure_message":"gave up on {{version}}"},
        \\ {"type":"mkdir_p","path":{"base":"etc","path":"after-miss"}}]
    ));
    if (p.flog.hasErrors()) return error.TerminateProcessMissWasAnError;
    if (!noteContains(&p.flog, "closing 1.0")) return error.NoticeNotPrinted;
    if (!noteContains(&p.flog, "gave up on 1.0")) return error.FailureMessageNotPrinted;
    if (!exists(p.ctx().io, try p.path("etc/after-miss"))) return error.FollowingStepDidNotRun;
}

test "must_succeed turns a missed terminate_process into an abort" {
    var p = try Probe.init();
    defer p.deinit();
    steps.runSteps(p.ctx(), try p.parse(
        \\[{"type":"terminate_process","name":"malt-gap-no-such-proc","must_succeed":true},
        \\ {"type":"mkdir_p","path":{"base":"etc","path":"after-fatal"}}]
    ));
    if (!p.flog.hasFatal()) return error.MustSucceedNotEnforced;
    if (exists(p.ctx().io, try p.path("etc/after-fatal"))) return error.PhaseDidNotAbort;
}

test "a symlink declared with uninstall is removed on uninstall only while it still points at its source" {
    var p = try Probe.init();
    defer p.deinit();
    const io = p.ctx().io;
    // Formula bases: `lib` is under the keg, `etc` under the prefix.
    const declared = try p.parse(
        \\[{"type":"symlink","source":{"base":"lib","path":"real"},"target":{"base":"etc","path":"alias"},"uninstall":true}]
    );
    steps.runSteps(p.ctx(), declared);
    if (p.flog.hasErrors()) {
        std.debug.print("refused: {s}\n", .{p.flog.entries()[0].detail});
        return error.SymlinkUninstallKeyRefused;
    }
    const link = try p.path("etc/alias");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.Io.Dir.readLinkAbsolute(io, link, &buf) catch return error.SymlinkNotCreated;

    // Guarded so a tree without the uninstall mode reports it instead of
    // failing to compile.
    if (!@hasDecl(steps, "runUninstallSteps")) return error.UninstallModeMissing;
    steps.runUninstallSteps(p.ctx(), declared);
    if (std.Io.Dir.readLinkAbsolute(io, link, &buf)) |_| return error.SymlinkSurvivedUninstall else |_| {}

    // Repointed by someone else: not ours to remove.
    try std.Io.Dir.symLinkAbsolute(io, try p.path("share/other"), link, .{});
    steps.runUninstallSteps(p.ctx(), declared);
    _ = std.Io.Dir.readLinkAbsolute(io, link, &buf) catch return error.ForeignSymlinkRemoved;
    if (p.flog.hasErrors()) return error.UninstallModeLoggedAnError;
}

test "a run step's declared env reaches the child, expanded" {
    var p = try Probe.init();
    defer p.deinit();
    const io = p.ctx().io;
    const a = p.arena.allocator();
    const libexec = try std.fmt.allocPrint(a, "{s}/libexec", .{p.keg});
    try std.Io.Dir.cwd().createDirPath(io, libexec);
    try std.Io.Dir.cwd().createDirPath(io, try p.path("etc"));
    const seen = try p.path("etc/seen.txt");
    {
        const f = try std.Io.Dir.createFileAbsolute(io, try std.fmt.allocPrint(a, "{s}/probe", .{libexec}), .{});
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.print("#!/bin/sh\n/usr/bin/env > '{s}'\n", .{seen});
        try w.interface.flush();
        try f.setPermissions(io, @enumFromInt(0o755));
    }
    steps.runSteps(p.ctx(), try p.parse(
        \\[{"type":"run","command":{"base":"libexec","path":"probe"},"env":{"MALT_GAP_PROBE":"v{{version}}"}}]
    ));
    if (p.flog.hasErrors()) {
        std.debug.print("refused: {s}\n", .{p.flog.entries()[0].detail});
        return error.RunEnvRefused;
    }
    const f = std.Io.Dir.openFileAbsolute(io, seen, .{}) catch return error.RunStepDidNotExecute;
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var r = f.reader(io, &.{});
    const dump = buf[0..try r.interface.readSliceShort(&buf)];
    if (std.mem.indexOf(u8, dump, "MALT_GAP_PROBE=v1.0\n") == null) return error.DeclaredEnvDidNotReachChild;
}

test "network_access on a run step stays refused" {
    var p = try Probe.init();
    defer p.deinit();
    steps.checkSteps(p.ctx(), try p.parse(
        \\[{"type":"run","command":{"path":"/bin/echo"},"network_access":true}]
    ));
    if (p.flog.entries().len != 1) return error.NetworkAccessNotRefused;
    try std.testing.expectEqualStrings("run with network_access", p.flog.entries()[0].detail);
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
  echo "PASS: cask flight steps honour terminate_process match/attempts/must_succeed, symlink uninstall, and run env"
else
  run_harness 2>&1 | grep -Ev '\.\.\.OK$' | tail -20 >&2
  echo "FAIL: a live cask flight step shape is still refused or unenforced" >&2
  exit 1
fi
