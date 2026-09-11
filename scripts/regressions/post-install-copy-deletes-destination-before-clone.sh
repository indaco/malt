#!/usr/bin/env bash
# Regression: the native post_install `copy` step deleted its destination and
# only then asked clonefile(2) to produce the replacement. Any clone failure —
# an unreadable child in a tap-shipped keg, ENOSPC, a part-way non-APFS
# fallback copy — returned false with the previous payload already unlinked,
# so a failed node upgrade left <prefix>/lib/node_modules/npm holding neither
# the old npm nor the new one.
#
# No CLI subcommand drives the native executor without a network install, so
# the guard follows the harness pattern of the env-scrub regression: a
# throwaway `zig test` root at the repo root (the module's sibling imports
# only resolve from inside the source tree). Unlike that one, `c_clonefile`
# keeps the real extern declaration — the failure under test is an actual
# clonefile(2) EACCES over a mode-000 directory, which creates nothing at the
# destination.
#
# Exits 0 when the previous destination survives a failed clone, non-zero
# (naming the destroyed payload) when it does not. No network required;
# one module compile, well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STUBS=$(mktemp -d)
HARNESS="$ROOT/.post-install-copy-clone-regression.$$.zig"
trap 'rm -rf "$STUBS" "$HARNESS"' EXIT

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

test "a failed copy leaves the previous destination intact" {
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

    // node's shape: the new npm in the keg, the installed one in the prefix.
    const keg = try std.fmt.allocPrint(a, "{s}/Cellar/node/1.0", .{prefix});
    const src = try std.fmt.allocPrint(a, "{s}/libexec/lib/node_modules/npm", .{keg});
    try std.Io.Dir.cwd().createDirPath(io, src);
    try writeFile(io, try std.fmt.allocPrint(a, "{s}/version.txt", .{src}), "new\n");

    // A mode-000 child makes clonefile(2) fail with EACCES and write nothing.
    const blocked = try std.fmt.allocPrint(a, "{s}/blocked", .{src});
    try std.Io.Dir.cwd().createDirPath(io, blocked);
    var bd = try std.Io.Dir.openDirAbsolute(io, blocked, .{});
    defer bd.close(io);
    const bf: std.Io.File = .{ .handle = bd.handle, .flags = .{ .nonblocking = false } };
    // Registered after tmp.cleanup so LIFO reopens the mode before teardown
    // walks it — a mode-000 directory cannot be reopened by its owner.
    defer bf.setPermissions(io, .fromMode(0o755)) catch {};
    try bf.setPermissions(io, .fromMode(0o000));

    const dstdir = try std.fmt.allocPrint(a, "{s}/lib/node_modules", .{prefix});
    const dest = try std.fmt.allocPrint(a, "{s}/npm", .{dstdir});
    try std.Io.Dir.cwd().createDirPath(io, dest);
    const installed = try std.fmt.allocPrint(a, "{s}/version.txt", .{dest});
    try writeFile(io, installed, "old\n");

    var flog = steps.FallbackLog.init(std.testing.allocator);
    defer flog.deinit();
    const ctx: steps.StepsCtx = .{
        .io = io,
        .allocator = a,
        .name = "node",
        .version = "1.0",
        .prefix = prefix,
        .keg_path = keg,
        .flog = &flog,
        .environ = .empty,
    };

    const formula =
        \\{"name":"node","versions":{"stable":"1.0"},"post_install_steps":
        \\[{"type":"copy","source":{"path":"{{libexec}}/lib/node_modules/npm"},
        \\  "target":{"path":"{{HOMEBREW_PREFIX}}/lib/node_modules"}}]}
    ;
    _ = steps.execute(ctx, formula);
    // An unsupported step only warns, so the run's own verdict says nothing
    // about the clone; the logged reason is what proves the probe still bites.
    if (!sawCloneFailure(&flog)) {
        std.debug.print("the clone was expected to fail; the probe no longer exercises the bug\n", .{});
        return error.CloneUnexpectedlySucceeded;
    }

    const got = readFile(io, a, installed) catch {
        std.debug.print("the installed payload at {s} is gone\n", .{dest});
        return error.PreviousDestinationDestroyed;
    };
    if (!std.mem.eql(u8, got, "old\n")) {
        std.debug.print("want 'old\\n' at {s}, got '{s}'\n", .{ installed, got });
        return error.PreviousDestinationClobbered;
    }

    // The staging and aside paths are internal; neither may outlive the step.
    for ([_][]const u8{ ".malt-incoming", ".malt-replaced" }) |suffix| {
        const leftover = try std.fmt.allocPrint(a, "{s}{s}", .{ dest, suffix });
        if (std.Io.Dir.accessAbsolute(io, leftover, .{})) |_| {
            std.debug.print("left {s} behind in the prefix\n", .{leftover});
            return error.ScratchPathLeaked;
        } else |_| {}
    }
}

fn sawCloneFailure(flog: *const steps.FallbackLog) bool {
    for (flog.entries()) |e| {
        if (std.mem.eql(u8, e.detail, "copy (clone failed)")) return true;
    }
    return false;
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

fn readFile(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    const buf = try a.alloc(u8, 4096);
    var r = f.reader(io, &.{});
    return buf[0..try r.interface.readSliceShort(buf)];
}
ZIG

run_harness() {
  (cd "$ROOT" && zig test -lc -framework Security -framework CoreFoundation \
    --dep c_clonefile --dep c_mount \
    -Mroot="$HARNESS" \
    -Mc_clonefile="$STUBS/c_clonefile.zig" \
    -Mc_mount="$STUBS/c_mount.zig")
}

if run_harness >/dev/null 2>&1; then
  echo "PASS: a failed post_install copy keeps the previous destination"
else
  run_harness 2>&1 | grep -Ev '\.\.\.OK$' | tail -20 >&2
  echo "FAIL: a failed copy step destroyed the previous payload" >&2
  exit 1
fi
